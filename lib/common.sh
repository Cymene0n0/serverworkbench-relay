#!/usr/bin/env bash
# Safe to source: definitions only, no filesystem/network/service mutations.

relay_error() { printf '错误：%s\n' "$*" >&2; return 1; }

validate_port() {
  local value="$1" minimum="${2:-1}" label="${3:-端口}"
  [[ "$value" =~ ^[1-9][0-9]{0,4}$ ]] || { relay_error "$label 必须为十进制端口。"; return 1; }
  ((10#$value >= minimum && 10#$value <= 65535)) || { relay_error "$label 超出允许范围。"; return 1; }
}

validate_host() {
  python3 - "$1" <<'PY'
import ipaddress,re,sys
s=sys.argv[1]
ok=bool(s) and len(s)<=253 and s.isascii() and not any(c.isspace() or ord(c)<32 for c in s)
if ok:
    try:
        ip=ipaddress.ip_address(s)
        ok='%' not in s and not ip.is_unspecified and not ip.is_multicast
    except ValueError:
        ok=not re.fullmatch(r'[0-9.]+',s) and bool(re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?',s))
        ok=ok and all(re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?',v) for v in s.split('.'))
if not ok:
    print('地址必须是纯 IP 或主机名，不能含协议、端口、路径、空白或凭据。',file=sys.stderr)
sys.exit(0 if ok else 1)
PY
}

validate_server_name() { validate_host "$1"; }

validate_token() {
  [[ "$1" =~ ^[a-f0-9]{64}$ ]] || { relay_error '节点 Token 必须为64位小写十六进制随机值。'; return 1; }
}

validate_options() {
  validate_host "$1" && validate_port "$2" 1024 '控制端口' && validate_port "$3" 1024 '游戏端口' &&
    validate_server_name "$4" || return 1
  [[ "$2" != "$3" ]] || { relay_error '控制端口和游戏端口不能相同。'; return 1; }
  [[ "$1" != *:* ]] || { relay_error '本版 Linux 节点监听 IPv4；请使用公网 IPv4 或具有 A 记录的域名。'; return 1; }
}

toml_quote() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1],ensure_ascii=True).replace("{",r"\u007b").replace("}",r"\u007d"))' "$1"; }

render_frps() {
  local control="$1" game="$2" cert key
  validate_port "$control" 1024 '控制端口' && validate_port "$game" 1024 '游戏端口' || return 1
  [[ "$control" != "$game" ]] || return 1
  cert="$(toml_quote "${SWB_CONFIG_DIR:-/etc/serverworkbench-relay}/server.crt")"
  key="$(toml_quote "${SWB_CONFIG_DIR:-/etc/serverworkbench-relay}/server.key")"
  cat <<EOF
# Managed by serverworkbench-relay; no dashboard or auxiliary listeners.
bindAddr = "0.0.0.0"
bindPort = $control
proxyBindAddr = "0.0.0.0"
auth.method = "token"
auth.token = "{{ .Envs.SWB_FRP_TOKEN }}"
auth.additionalScopes = ["HeartBeats", "NewWorkConns"]
transport.tls.force = true
transport.tls.certFile = $cert
transport.tls.keyFile = $key
allowPorts = [{ single = $game }]
maxPortsPerClient = 1
detailedErrorsToClient = false
log.to = "console"
log.level = "info"
log.disablePrintColor = true
EOF
}

render_service() {
  cat <<EOF
# Managed by serverworkbench-relay
[Unit]
Description=ServerWorkbench frp relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=swb-frp
Group=swb-frp
EnvironmentFile=${SWB_CONFIG_DIR:-/etc/serverworkbench-relay}/frps.env
ExecStart=${SWB_INSTALL_DIR:-/usr/local/lib/serverworkbench-relay}/frps -c ${SWB_CONFIG_DIR:-/etc/serverworkbench-relay}/frps.toml
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
}

write_client_json() {
  python3 - "$1" "$2" "$3" "$4" "$5" "$6" <<'PY'
import json,sys
out,server,control,game,name,digest=sys.argv[1:]
record={'schemaVersion':1,'managedBy':'serverworkbench-relay','serverAddress':server,
        'serverPort':int(control),'remotePort':int(game),'serverName':name,
        'caFile':'ca.crt','caSha256':digest,
        'token':'请在节点本地执行 sudo swb-relay show-token 后手动填写；此文件不含 Token',
        'instructions':'在开服工坊的 frp 穿透配置中手动填写；不要将本文件当成可执行配置导入。'}
with open(out,'x',encoding='utf-8') as f: json.dump(record,f,ensure_ascii=False,indent=2);f.write('\n')
PY
}
