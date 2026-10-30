#!/usr/bin/env bash
# Production-path smoke test: disposable GitHub-hosted Ubuntu runner only.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_ENVIRONMENT:-} == github-hosted && ${RUNNER_OS:-} == Linux ]] || {
    printf 'Refusing production-path test outside a disposable GitHub-hosted Linux runner.\n' >&2
    exit 1
}
(( EUID != 0 )) || { printf 'Run as the ordinary runner account, with sudo available.\n' >&2; exit 1; }
[[ -n ${RUNNER_TEMP:-} && -d $RUNNER_TEMP ]] || exit 1
SERVICE=serverworkbench-relay.service
CONFIG=/etc/serverworkbench-relay
INSTALL=/usr/local/lib/serverworkbench-relay
for path in "$CONFIG" "$INSTALL" /usr/local/bin/swb-relay "/etc/systemd/system/$SERVICE"; do
    [[ ! -e $path && ! -L $path ]] || { printf 'Refusing to replace an existing node.\n' >&2; exit 1; }
done
bundle_parent=$(mktemp -d "$RUNNER_TEMP/swb-systemd-smoke-XXXXXXXX")
blocker_pid=''
cleanup() {
    local result=$?
    trap - EXIT
    if [[ -n $blocker_pid ]]; then kill "$blocker_pid" 2>/dev/null || true; wait "$blocker_pid" 2>/dev/null || true; fi
    if [[ -x /usr/local/bin/swb-relay ]]; then
        sudo /usr/local/bin/swb-relay uninstall || result=1
    fi
    if (( result )); then
        sudo journalctl -u "$SERVICE" -n 60 --no-pager || true
    fi
    # Only public CA/JSON files in this runner-created directory are removed.
    rm -rf -- "$bundle_parent"
    exit "$result"
}
trap cleanup EXIT
# A port collision must be a failed deployment, even if systemd briefly reports
# a just-started process active. The retained first-install files must uninstall.
python3 - "$bundle_parent/blocker-ready" <<'PY' &
import pathlib,socket,sys
with socket.socket() as listener:
    listener.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
    listener.bind(('127.0.0.1',17070)); listener.listen()
    pathlib.Path(sys.argv[1]).touch()
    while True:
        connection,_=listener.accept(); connection.close()
PY
blocker_pid=$!
for _ in {1..50}; do [[ ! -e $bundle_parent/blocker-ready ]] || break; sleep .1; done
[[ -e $bundle_parent/blocker-ready ]]
if sudo bash "$ROOT/relay.sh" install --server 127.0.0.1 --control-port 17070 --game-port 17777; then
    printf 'An occupied control port was falsely reported as a successful deployment.\n' >&2
    exit 1
fi
kill "$blocker_pid"; wait "$blocker_pid" 2>/dev/null || true; blocker_pid=''
retained=$(sudo sha256sum "$CONFIG/frps.env" "$CONFIG/ca.crt" "$CONFIG/server.key")
sudo /usr/local/bin/swb-relay uninstall
[[ ! -e $INSTALL/frps && ! -e /etc/systemd/system/$SERVICE ]]
sudo bash "$ROOT/relay.sh" install --server 127.0.0.1 --control-port 17070 --game-port 17777
[[ $retained == "$(sudo sha256sum "$CONFIG/frps.env" "$CONFIG/ca.crt" "$CONFIG/server.key")" ]]
sudo systemctl is-active --quiet "$SERVICE"
sudo systemctl is-enabled --quiet "$SERVICE"
[[ $(sudo systemctl show -p User --value "$SERVICE") == swb-frp ]]
[[ $(sudo systemctl show -p Group --value "$SERVICE") == swb-frp ]]
pid=$(sudo systemctl show -p MainPID --value "$SERVICE")
[[ $pid =~ ^[1-9][0-9]*$ ]]
[[ $(stat -c '%u' "/proc/$pid") == "$(id -u swb-frp)" ]]
[[ $(sudo stat -c '%a:%U:%G' "$CONFIG") == 750:root:swb-frp ]]
[[ $(sudo stat -c '%a:%U:%G' "$CONFIG/frps.env") == 600:root:root ]]
[[ $(sudo stat -c '%a:%U:%G' "$CONFIG/server.key") == 640:root:swb-frp ]]
sudo -u swb-frp test -r "$CONFIG/server.key"
sudo -u swb-frp test -r "$CONFIG/frps.toml"
if sudo -u swb-frp test -r "$CONFIG/frps.env"; then
    printf 'Dedicated service account can read the root-only Token file.\n' >&2; exit 1
fi
sudo test ! -e "$CONFIG/ca.key"
sudo /usr/local/bin/swb-relay export-client --output "$bundle_parent/client"
[[ $(stat -c '%u:%g:%a' "$bundle_parent/client") == "$(id -u):$(id -g):700" ]]
for file in ca.crt client.json; do
    [[ $(stat -c '%u:%g:%a' "$bundle_parent/client/$file") == "$(id -u):$(id -g):600" ]]
    [[ -r $bundle_parent/client/$file ]]
done
# Verify the real systemd process loaded its protected key and serves the
# production CA/name. This handshake is not a claim of public game connectivity.
python3 - "$bundle_parent/client/ca.crt" <<'PY'
import socket,ssl,sys,time
context=ssl.create_default_context(cafile=sys.argv[1])
for attempt in range(40):
    try:
        with socket.create_connection(('127.0.0.1',17070),timeout=2) as sock:
            with context.wrap_socket(sock,server_hostname='kaifu-relay') as tls:
                assert tls.getpeercert()
        break
    except (OSError,ssl.SSLError):
        if attempt==39: raise
        time.sleep(.25)
PY
before=$(sudo sha256sum "$CONFIG/frps.env" "$CONFIG/ca.crt" "$CONFIG/server.key")
sudo bash "$ROOT/relay.sh" install --server 127.0.0.1 --control-port 17070 --game-port 17777
[[ $before == "$(sudo sha256sum "$CONFIG/frps.env" "$CONFIG/ca.crt" "$CONFIG/server.key")" ]]
[[ $pid == "$(sudo systemctl show -p MainPID --value "$SERVICE")" ]]
sudo /usr/local/bin/swb-relay uninstall
if sudo systemctl is-active --quiet "$SERVICE"; then printf 'Uninstall left an active service.\n' >&2; exit 1; fi
if sudo systemctl is-enabled --quiet "$SERVICE"; then printf 'Uninstall left an enabled service.\n' >&2; exit 1; fi
[[ ! -e $INSTALL/frps && ! -e /etc/systemd/system/$SERVICE ]]
[[ $before == "$(sudo sha256sum "$CONFIG/frps.env" "$CONFIG/ca.crt" "$CONFIG/server.key")" ]]
printf 'PASS occupied-port rejection, recovery, dedicated service account, TLS handshake, export ownership, idempotence and uninstall\n'
