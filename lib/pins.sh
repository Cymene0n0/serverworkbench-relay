#!/usr/bin/env bash
# shellcheck disable=SC2034 # Version constants are consumed by sourcing scripts.
# Official release assets; deliberately not a moving "latest" URL.
FRP_VERSION='0.71.1'
SWB_RELAY_VERSION='0.1.0'

archive_sha256() {
  case "$1" in
    amd64) printf '%s\n' '1d9875210972a5d1a62b2dc4c48df45ab0af05d3ca1b5e494a014428259df803' ;;
    arm64) printf '%s\n' '8edf590b0c396fa42f9c147121a76af83cfc2002b08f5aef0ea1008c43482019' ;;
    *) printf 'Unsupported architecture: %s\n' "$1" >&2; return 1 ;;
  esac
}
