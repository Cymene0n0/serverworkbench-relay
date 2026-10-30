#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
# Loading these libraries must not install packages, create users or change files.
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/pins.sh
source "$ROOT/lib/pins.sh"
passed=0 failed=0
test_case() {
    local title=$1; shift
    if ( "$@" ); then
        printf 'PASS %s\n' "$title"; passed=$((passed + 1))
    else
        printf 'FAIL %s\n' "$title" >&2; failed=$((failed + 1))
    fi
}
rejects() { if ( "$@" >/dev/null 2>&1 ); then return 1; fi; }
pins() {
    [[ $FRP_VERSION == 0.71.1 ]] || return 1
    [[ $(archive_sha256 amd64) == 1d9875210972a5d1a62b2dc4c48df45ab0af05d3ca1b5e494a014428259df803 ]] || return 1
    [[ $(archive_sha256 arm64) == 8edf590b0c396fa42f9c147121a76af83cfc2002b08f5aef0ea1008c43482019 ]] || return 1
    rejects archive_sha256 riscv64
}
ports_accept() {
    validate_port 1 1 control && validate_port 65535 1 control &&
        validate_port 1024 1024 game && validate_port 7777 1024 game
}
ports_reject() {
    local value
    for value in '' 0 -1 65536 '+7000' '7e3' '7000;id' ' 7000' '7000 ' $'7000\n'; do
        rejects validate_port "$value" 1 control || return 1
    done
    rejects validate_port 1023 1024 game
}
hosts_accept() {
    local value
    for value in relay.example.com kaifu-relay 203.0.113.25 2001:db8::25; do
        validate_host "$value" || return 1
    done
}
hosts_reject() {
    local value
    # shellcheck disable=SC2016 # These are malicious literal inputs, not expansions.
    for value in '' 'https://relay.example.com' 'relay.example.com:7000' 'user@relay.example.com' \
        'relay.example.com/path' 'relay example.com' '-bad.example' '"evil"' \
        '{{ .Envs.OTHER_SECRET }}' '$(touch /tmp/swb-must-not-exist)' $'relay.example.com\n'; do
        rejects validate_host "$value" || return 1
    done
}
names_reject() {
    local value
    for value in '' '*.example.com' 'https://example.com' 'a b' $'example.com\n' \
        'example.com;id' 'x"' '\\server\ca' '{{.Envs.HOME}}'; do
        rejects validate_server_name "$value" || return 1
    done
}
tokens_accept() {
    validate_token '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' &&
        validate_token "$(printf 'a%.0s' {1..64})"
}
tokens_reject() {
    local valid value
    valid=$(printf 'a%.0s' {1..64})
    for value in '' short "$(printf 'a%.0s' {1..63})" "$(printf 'a%.0s' {1..65})" "$(printf 'A%.0s' {1..64})" \
        "$valid " "$valid\"" "$valid'" "$valid=" "$valid{" "$valid\$" "$valid\\" "$valid"$'\n'; do
        rejects validate_token "$value" || return 1
    done
}
client_json() {
    local file="$WORK/client 中文.json" digest
    digest=$(printf 'a%.0s' {1..64})
    write_client_json "$file" 2001:db8::25 7000 7777 kaifu-relay "$digest" || return 1
    python3 - "$file" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); r=json.loads(p.read_text())
assert r['serverAddress']=='2001:db8::25'
assert r['serverPort']==7000 and r['remotePort']==7777
assert r['serverName']=='kaifu-relay'
assert r['caFile']=='ca.crt' and r['caSha256']=='a'*64
assert 'PRIVATE KEY' not in p.read_text()
assert not any(k.lower() in ('privatekey','cakey','servertoken','swb_frp_token') for k in r)
PY
    local before
    before=$(sha256sum "$file")
    rejects write_client_json "$file" other.example.com 7000 7777 other-name "$digest" || return 1
    [[ $(sha256sum "$file") == "$before" ]]
}
options() {
    validate_options relay.example.com 7000 7777 kaifu-relay || return 1
    rejects validate_options relay.example.com 7777 7777 kaifu-relay || return 1
    rejects validate_options relay.example.com 7000 80 kaifu-relay || return 1
    rejects validate_options 2001:db8::25 7000 7777 kaifu-relay || return 1
    rejects validate_options 'http://example.com' 7000 7777 kaifu-relay
}
render_config() {
    SWB_CONFIG_DIR=$WORK/config
    SWB_INSTALL_DIR=$WORK/install
    export SWB_CONFIG_DIR SWB_INSTALL_DIR
    render_frps 7000 7777 > "$WORK/frps.toml"
    python3 - "$WORK/frps.toml" <<'PY'
import pathlib,re,sys
s=pathlib.Path(sys.argv[1]).read_text()
expected = {
    'bindPort': '7000', 'auth.method': '"token"',
    'auth.token': '"{{ .Envs.SWB_FRP_TOKEN }}"',
    'transport.tls.force': 'true', 'maxPortsPerClient':'1',
}
for key,value in expected.items():
    assert re.search(r'^\s*'+re.escape(key)+r'\s*=\s*'+re.escape(value)+r'\s*$',s,re.M),key
assert 'HeartBeats' in s and 'NewWorkConns' in s
assert re.search(r'allowPorts\s*=\s*\[\s*\{\s*single\s*=\s*7777\s*\}\s*\]',s)
for key in ('webServer.port','vhostHTTPPort','vhostHTTPSPort','kcpBindPort','quicBindPort',
            'transport.tls.trustedCaFile'):
    assert not re.search(r'^\s*'+re.escape(key)+r'\s*=',s,re.M),key
assert re.search(r'^\s*transport\.tls\.certFile\s*=\s*"[^"\n]+"',s,re.M)
assert re.search(r'^\s*transport\.tls\.keyFile\s*=\s*"[^"\n]+"',s,re.M)
PY
}
service() {
    SWB_CONFIG_DIR=$WORK/config
    SWB_INSTALL_DIR=$WORK/install
    export SWB_CONFIG_DIR SWB_INSTALL_DIR
    render_service > "$WORK/service"
    python3 - "$WORK/service" <<'PY'
import pathlib,re,sys
s=pathlib.Path(sys.argv[1]).read_text()
for key,value in [('User','swb-frp'),('Group','swb-frp'),('NoNewPrivileges','true')]:
    assert re.search(r'^'+key+r'\s*=\s*'+value+r'\s*$',s,re.M),(key,value)
assert re.search(r'^EnvironmentFile\s*=\s*.+frps\.env\s*$',s,re.M)
assert re.search(r'^ExecStart\s*=\s*/.+frps.+-c\s+/.+frps\.toml\s*$',s,re.M)
assert not re.search(r'^Environment\s*=.*SWB_FRP_TOKEN=',s,re.M)
PY
}
test_case 'Official amd64/arm64 pins and unsupported architecture rejection' pins
test_case 'Control/game port boundary values' ports_accept
test_case 'Invalid, injected and out-of-range ports are rejected' ports_reject
test_case 'DNS, IPv4 and IPv6 endpoints are accepted' hosts_accept
test_case 'Endpoint URLs, credentials, templates and shell injection are rejected' hosts_reject
test_case 'Certificate-name injection is rejected' names_reject
test_case 'Generated-token format accepts exactly 64 lowercase hex characters' tokens_accept
test_case 'Wrong token lengths, alphabet, quotes and trailing newline are rejected' tokens_reject
test_case 'Port collision, privileged game port and IPv6-only node configuration are rejected' options
test_case 'Minimal server config keeps TLS, token environment and one allowed port' render_config
test_case 'Service runs as dedicated user and reads token from environment file' service
test_case 'Client export preserves IPv6/Unicode, omits private keys and refuses overwrite' client_json
printf 'RESULT passed=%d failed=%d\n' "$passed" "$failed"
(( failed == 0 ))
