#!/usr/bin/env bash

set -eu
set -o pipefail

readonly PROGDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BUILDPACKDIR="$(cd "${PROGDIR}/.." && pwd)"

# shellcheck source=SCRIPTDIR/.util/print.sh
source "${BUILDPACKDIR}/scripts/.util/print.sh"

function main() {
  local targets=()
  while [[ "${#}" != 0 ]]; do
    case "${1}" in
      --help|-h)
        shift 1
        usage
        exit 0
        ;;

      --target)
        targets+=("${2}")
        shift 2
        ;;

      "")
        shift 1
        ;;

      *)
        util::print::error "unknown argument \"${1}\""
    esac
  done

  # Read targets from buildpack.toml if none provided
  if [[ ${#targets[@]} -eq 0 ]]; then
    local buildpack_toml="${BUILDPACKDIR}/buildpack.toml"
    if [[ -f "${buildpack_toml}" ]] && command -v yj >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
      util::print::info "Reading targets from ${buildpack_toml}..."
      local targets_json
      targets_json=$(cat "${buildpack_toml}" | yj -tj | jq -r '.targets[]? | "\(.os)/\(.arch)"' 2>/dev/null || echo "")
      while IFS= read -r target; do
        [[ -n "${target}" ]] && targets+=("${target}")
      done <<< "${targets_json}"
      [[ ${#targets[@]} -gt 0 ]] && util::print::info "Found ${#targets[@]} target(s): ${targets[*]}"
    fi
  fi

  if [[ ${#targets[@]} -eq 0 ]]; then
    targets=("linux/amd64" "linux/arm64")
    util::print::info "No targets found; defaulting to linux/amd64 linux/arm64"
  fi

  run::build "${targets[@]}"
  cmd::build "${targets[@]}"

  # Backwards compatibility: copy amd64 bin to bin/ root if only amd64
  if [[ ${#targets[@]} -eq 1 && "${targets[0]}" == "linux/amd64" ]]; then
    cp -r "${BUILDPACKDIR}/linux/amd64/bin" "${BUILDPACKDIR}/bin"
  fi
  
  return 0
}

function usage() {
  cat <<-USAGE
build.sh [OPTIONS]

Builds the buildpack executables.

OPTIONS
  --help  -h  prints the command usage
USAGE
}

function run::build() {
  local targets=("${@}")
  [[ -f "${BUILDPACKDIR}/run/main.go" ]] || return 0
  for target in "${targets[@]}"; do
    local os arch
    os=$(echo "${target}" | cut -d'/' -f1)
    arch=$(echo "${target}" | cut -d'/' -f2)
    mkdir -p "${BUILDPACKDIR}/${os}/${arch}/bin"
    util::print::title "Building run for ${target}..."
    (cd "${BUILDPACKDIR}" && \
     GOOS="${os}" GOARCH="${arch}" CGO_ENABLED=0 \
       go build -ldflags="-s -w" -o "${os}/${arch}/bin/run" "./run")
    names=("detect")
    if [ -f "${BUILDPACKDIR}/extension.toml" ]; then
      names+=("generate")
    else
      names+=("build")
    fi
    for name in "${names[@]}"; do
      (cd "${BUILDPACKDIR}/${os}/${arch}/bin" && ln -sf "run" "${name}")
    done
  done
}

function cmd::build() {
  local targets=("${@}")
  [[ -d "${BUILDPACKDIR}/cmd" ]] || return 0
  for src in "${BUILDPACKDIR}"/cmd/*; do
    local name
    name="$(basename "${src}")"
    [[ -f "${src}/main.go" ]] || continue
    for target in "${targets[@]}"; do
      local os arch
      os=$(echo "${target}" | cut -d'/' -f1)
      arch=$(echo "${target}" | cut -d'/' -f2)
      util::print::title "Building ${name} for ${target}..."
      (cd "${BUILDPACKDIR}" && \
       GOOS="${os}" GOARCH="${arch}" CGO_ENABLED=0 \
         go build -ldflags="-s -w" -o "${os}/${arch}/bin/${name}" "${src}/main.go")
    done
  done
  return 0
}

main "${@:-}"
