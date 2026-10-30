#!/usr/bin/env bash
# Download a fixed, checksum-verified manager payload before running it.
set -euo pipefail
readonly BOOTSTRAP_VERSION='0.1.0'
readonly REPOSITORY='Cymene0n0/serverworkbench-relay'
readonly CORE_REF='main'

usage() {
  cat <<'EOF'
ServerWorkbench Relay bootstrap 0.1.0
Usage: sudo bash install.sh --server PUBLIC_IP_OR_HOST [options]
       sudo bash install.sh install --server PUBLIC_IP_OR_HOST [options]
Options: --control-port 7000 --game-port 7777 --server-name kaifu-relay
         --no-start --no-install-deps --open-firewall --dry-run
An existing installation retains its Token, certificates and ports.
EOF
}
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --version) printf '%s\n' "$BOOTSTRAP_VERSION"; exit 0 ;;
esac
if (($#==0)); then usage >&2; exit 2; fi
if ((EUID!=0)); then printf '请使用 sudo/root 执行安装。\n' >&2; exit 1; fi
for tool in curl sha256sum mktemp mkdir chmod rm; do
  command -v "$tool" >/dev/null || { printf '缺少引导依赖：%s\n' "$tool" >&2; exit 1; }
done
work_dir="$(mktemp -d /tmp/swb-relay-bootstrap.XXXXXXXX)"
cleanup() {
  case "${work_dir:-}" in /tmp/swb-relay-bootstrap.*) rm -rf -- "$work_dir" ;; esac
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -m 700 "$work_dir/lib"
verify_file() {
  local relative="$1" expected="$2"
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --tlsv1.2 --connect-timeout 15 --max-time 120 --retry 2 \
    "https://raw.githubusercontent.com/$REPOSITORY/$CORE_REF/$relative" \
    --output "$work_dir/$relative"
  printf '%s  %s\n' "$expected" "$work_dir/$relative" | sha256sum --check --status || {
    printf '管理脚本校验失败：%s；没有执行下载内容。\n' "$relative" >&2; return 1;
  }
}
# BEGIN PAYLOAD PINS -- regenerated from reviewed repository files.
verify_file 'relay.sh' '7c4ba4f6acb311b17900284371dcbb1e4c03f022e8a79ffa0608a9cf5ebc4c74'
verify_file 'lib/common.sh' '0426d7df6bb22bfd8fab7ba6117e1c8b842f90d17b2d638ca6933c6b6ef98774'
verify_file 'lib/pins.sh' '409c719d2d742c347a2032ee17566a7fa48fa09b4a2512e242892e96af49fe50'
# END PAYLOAD PINS
chmod 700 "$work_dir/relay.sh"
if [[ "${1:-}" == install ]]; then shift; fi
# Do not exec: the EXIT trap must clean up the private bootstrap directory.
bash "$work_dir/relay.sh" install "$@"
