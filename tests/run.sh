#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/pins.sh
source "$ROOT/lib/pins.sh"
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || {
    printf 'Native integration runner currently requires Linux x86_64. Unit tests also validate arm64 pins.\n' >&2
    exit 1
}
fixture_work=''
cleanup() { [[ -z $fixture_work ]] || rm -rf -- "$fixture_work"; }
trap cleanup EXIT
archive=${SWB_RELAY_FIXTURE_ARCHIVE:-}
if [[ -z $archive ]]; then
    fixture_work=$(mktemp -d /tmp/swb-relay-fixture-XXXXXXXX)
    archive=$fixture_work/frp.tar.gz
    curl --fail --show-error --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 10 --max-time 180 --retry 2 \
        --output "$archive" \
        "https://github.com/fatedier/frp/releases/download/v$FRP_VERSION/frp_${FRP_VERSION}_linux_amd64.tar.gz"
fi
[[ $(sha256sum "$archive" | cut -d ' ' -f1) == "$(archive_sha256 amd64)" ]] || {
    printf 'Official Linux fixture SHA256 mismatch.\n' >&2
    exit 1
}
bash "$ROOT/tests/unit.sh"
python3 "$ROOT/tests/lifecycle.py" "$archive"
