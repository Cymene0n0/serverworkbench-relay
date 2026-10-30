#!/usr/bin/env bash
# Managed by serverworkbench-relay. Linux manager; never operates game/world files.
set +xv
set -Eeuo pipefail
SWB_SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/pins.sh
source "$SWB_SOURCE_DIR/lib/pins.sh"
# shellcheck source=lib/common.sh
source "$SWB_SOURCE_DIR/lib/common.sh"

die() { relay_error "$*"; exit 1; }
note() { printf '%s\n' "$*"; }
TESTING=0
TEMP_DIR=''
BACKUP_DIR=''
ROLLBACK_REQUIRED=0
WAS_ACTIVE=0
WAS_ENABLED=0
HAD_CONFIG=0
HAD_BINARY=0
HAD_UNIT=0
HAD_RUNTIME=0
SERVICE='serverworkbench-relay.service'
NO_START=0
OPEN_FIREWALL=0
NO_INSTALL_DEPS=0
DRY_RUN=0
ROTATE_CA=0
SERVER=''
CONTROL=''
GAME=''
SERVER_NAME=''
EXPORT_OUTPUT=''

usage() {
  cat <<'EOF'
ServerWorkbench Relay 0.1.0 / frp 0.71.1

sudo bash relay.sh install --server 公网IP或域名 [选项]
sudo swb-relay status
sudo swb-relay config
sudo swb-relay show-token                  # 只允许交互终端显示
sudo swb-relay export-client [--output 新目录]
sudo swb-relay upgrade                     # 固定版本重装，保留证书/Token/端口
sudo swb-relay renew --rotate-ca            # 显式更新 CA，Windows 必须重新导入
sudo swb-relay uninstall                   # 停用服务，保留凭据和备份

安装选项：--control-port 7000 --game-port 7777 --server-name kaifu-relay
          --no-start --open-firewall --no-install-deps --dry-run
不会自动修改云安全组、防火墙策略、代理、路由或时区。
--open-firewall 仅向已启用的 UFW/firewalld 添加本实例两个 TCP 端口。
EOF
}

reject_symlink_path() {
  local path="$1" current
  [[ "$path" == /* && "$path" != *$'\n'* && "$path" != *$'\r'* ]] || die '管理路径无效。'
  current="$path"
  while [[ "$current" != / ]]; do
    [[ ! -L "$current" ]] || die "拒绝符号链接管理路径：$current"
    current="$(dirname -- "$current")"
  done
}

init_paths() {
  local prefix=''
  if [[ "${SWB_RELAY_TESTING:-0}" == 1 ]]; then
    prefix="${SWB_RELAY_TEST_ROOT:-}"
    [[ "$prefix" =~ ^/tmp/[A-Za-z0-9_./-]+$ && "$prefix" != *'/../'* && "$prefix" != */.. && -f "$prefix/.swb-relay-test-root" ]] || die '测试模式必须使用带标记的独立 /tmp 目录。'
    reject_symlink_path "$prefix"
    TESTING=1
  elif [[ -n "${SWB_RELAY_TEST_ROOT:-}${SWB_RELAY_FIXTURE_ARCHIVE:-}" ]]; then
    die '测试路径/下载夹具只能在显式测试模式使用。'
  fi
  SWB_CONFIG_DIR="$prefix/etc/serverworkbench-relay"
  SWB_STATE_DIR="$prefix/var/lib/serverworkbench-relay"
  SWB_INSTALL_DIR="$prefix/usr/local/lib/serverworkbench-relay"
  SWB_WRAPPER="$prefix/usr/local/bin/swb-relay"
  SWB_UNIT="$prefix/etc/systemd/system/$SERVICE"
  local path
  for path in "$SWB_CONFIG_DIR" "$SWB_STATE_DIR" "$SWB_INSTALL_DIR" "$SWB_WRAPPER" "$SWB_UNIT"; do reject_symlink_path "$path"; done
}

service_cmd() {
  if ((TESTING)); then
    mkdir -p "$SWB_STATE_DIR"
    printf '%s\n' "$*" >> "$SWB_RELAY_TEST_ROOT/service-events"
    case "$1" in
      is-active) [[ -f "$SWB_RELAY_TEST_ROOT/service-active" ]] ;;
      is-enabled) [[ -f "$SWB_RELAY_TEST_ROOT/service-enabled" ]] ;;
      show)
        if [[ -f "$SWB_UNIT" || -f "$SWB_RELAY_TEST_ROOT/service-active" ]]; then printf 'loaded\n'; else printf 'not-found\n'; fi ;;
      start|restart)
        [[ ! -f "$SWB_RELAY_TEST_ROOT/fail-restart" ]] || return 1
        : > "$SWB_RELAY_TEST_ROOT/service-active" ;;
      stop)
        [[ ! -f "$SWB_RELAY_TEST_ROOT/fail-stop" ]] || return 1
        rm -f -- "$SWB_RELAY_TEST_ROOT/service-active" ;;
      enable) : > "$SWB_RELAY_TEST_ROOT/service-enabled" ;;
      disable)
        [[ ! -f "$SWB_RELAY_TEST_ROOT/fail-disable" ]] || return 1
        rm -f -- "$SWB_RELAY_TEST_ROOT/service-enabled" ;;
      daemon-reload) return 0 ;;
      *) die '未知测试服务操作。' ;;
    esac
  else
    systemctl "$@"
  fi
}

root_required() { ((TESTING || DRY_RUN || EUID == 0)) || die '请使用 sudo 运行管理命令。'; }

platform_check() {
  [[ "$(uname -s)" == Linux ]] || die '仅支持 Linux。'
  case "$(uname -m)" in x86_64) ARCH=amd64 ;; aarch64|arm64) ARCH=arm64 ;; *) die '仅支持 Linux amd64/arm64。' ;; esac
  ((TESTING)) && return 0
  local os_id os_version
  os_id="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '\"')"
  os_version="$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '\"')"
  case "$os_id" in
    ubuntu) if ! [[ "$os_version" =~ ^([0-9]+)\.([0-9]+)$ ]] || ((10#${BASH_REMATCH[1]} < 22)); then die '需要 Ubuntu 22.04 或更新版本。'; fi ;;
    debian) if ! [[ "$os_version" =~ ^([0-9]+)(\.[0-9]+)?$ ]] || ((10#${BASH_REMATCH[1]} < 12)); then die '需要 Debian 12 或更新版本。'; fi ;;
    *) die '目前支持 Ubuntu 22.04+ / Debian 12+，不自动猜测其他发行版。' ;;
  esac
}

dependencies() {
  local operation="${1:-install}" cmd package missing=()
  for cmd in curl openssl python3 tar sha256sum flock install; do
    command -v "$cmd" >/dev/null 2>&1 && continue
    case "$cmd" in sha256sum|install) package=coreutils ;; flock) package=util-linux ;; *) package="$cmd" ;; esac
    missing+=("$package")
  done
  if ! ((TESTING)) && ! dpkg-query -W -f='${Status}' ca-certificates 2>/dev/null | grep -q 'install ok installed'; then missing+=(ca-certificates); fi
  if ((${#missing[@]})); then
    [[ "$operation" == install || "$operation" == upgrade || "$operation" == renew ]] || die "缺少依赖：${missing[*]}；请先运行 install。"
    ((TESTING == 0 && NO_INSTALL_DEPS == 0)) || die "缺少依赖：${missing[*]}"
    command -v apt-get >/dev/null 2>&1 || die '没有 apt-get，不能安装缺失依赖。'
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
  fi
  if ! ((TESTING)); then
    command -v systemctl >/dev/null 2>&1 || die '需要已安装 systemd 的 Linux 系统。'
    if [[ "$operation" == install || "$operation" == upgrade || "$operation" == renew ]] && ! ((NO_START)); then systemctl show-environment >/dev/null 2>&1 || die 'systemd 服务管理器未运行；容器/WSL 请使用 --no-start 仅准备文件。'; fi
  fi
}

owned_directory_or_absent() {
  local dir="$1"
  [[ ! -e "$dir" ]] && return 0
  [[ -d "$dir" && ! -L "$dir" ]] || die "不是普通目录：$dir"
  [[ -z "$(find "$dir" -mindepth 1 -maxdepth 1 -print -quit)" ]] && return 0
  [[ -f "$dir/.managed" && "$(cat "$dir/.managed")" == serverworkbench-relay-v1 ]] || die "已有未受本项目管理的数据，拒绝覆盖：$dir"
}

check_existing_paths() {
  owned_directory_or_absent "$SWB_CONFIG_DIR"
  owned_directory_or_absent "$SWB_STATE_DIR"
  owned_directory_or_absent "$SWB_INSTALL_DIR"
  if [[ -e "$SWB_UNIT" ]]; then grep -q '^# Managed by serverworkbench-relay$' "$SWB_UNIT" || die '同名 systemd 服务属于其他配置，拒绝覆盖。'; fi
  if [[ -e "$SWB_WRAPPER" ]]; then grep -q '^# Managed by serverworkbench-relay$' "$SWB_WRAPPER" || die '同名管理命令属于其他程序，拒绝覆盖。'; fi
}

read_token() {
  python3 - "$1" <<'PY'
import pathlib,re,sys
p=pathlib.Path(sys.argv[1])
if p.stat().st_size>256: raise SystemExit('Token 文件大小无效。')
s=p.read_text(encoding='ascii')
match=re.fullmatch(r'SWB_FRP_TOKEN=([a-f0-9]{64})\n?',s)
if not match: raise SystemExit('Token 文件无效；不会把它作为 Shell 脚本执行。')
print(match.group(1))
PY
}

load_saved() {
  [[ -f "$SWB_CONFIG_DIR/.managed" && -f "$SWB_CONFIG_DIR/node.json" ]] || die '尚未安装本项目管理的节点。'
  local data
  data="$(python3 - "$SWB_CONFIG_DIR/node.json" <<'PY'
import json,pathlib,re,sys
p=pathlib.Path(sys.argv[1])
if p.stat().st_size>65536: raise SystemExit('节点元数据超过大小限制。')
x=json.load(open(p,encoding='utf-8'))
if x.get('managedBy')!='serverworkbench-relay' or x.get('schemaVersion')!=1: raise SystemExit('节点元数据身份无效。')
for key in ('serverAddress','serverName','binarySha256','caSha256'):
    if not isinstance(x.get(key),str) or any(c in x[key] for c in '\n\r\x00'): raise SystemExit('节点元数据字段无效。')
for key in ('binarySha256','caSha256'):
    if not re.fullmatch('[a-f0-9]{64}',x[key]): raise SystemExit('节点摘要字段无效。')
for key in ('serverPort','remotePort'):
    if type(x.get(key)) is not int: raise SystemExit('端口元数据无效。')
for key in ('serverAddress','serverPort','remotePort','serverName','binarySha256','caSha256'): print(x[key])
PY
)" || die '无法读取节点元数据。'
  local values=()
  mapfile -t values <<< "$data"
  ((${#values[@]} == 6)) || die '节点元数据不完整。'
  SAVED_SERVER="${values[0]}"; SAVED_CONTROL="${values[1]}"; SAVED_GAME="${values[2]}"; SAVED_NAME="${values[3]}"; SAVED_BINARY_SHA="${values[4]}"; SAVED_CA_SHA="${values[5]}"
  validate_options "$SAVED_SERVER" "$SAVED_CONTROL" "$SAVED_GAME" "$SAVED_NAME" || die '已保存配置无效。'
  [[ "$(sha256sum "$SWB_CONFIG_DIR/ca.crt" | cut -d ' ' -f1)" == "$SAVED_CA_SHA" ]] || die 'CA 文件已变化，拒绝继续。'
  read_token "$SWB_CONFIG_DIR/frps.env" >/dev/null || die '无法读取节点 Token。'
}

verify_pki() {
  local dir="$1" name="$2" key_public cert_public
  if python3 -c 'import ipaddress,sys;ipaddress.ip_address(sys.argv[1])' "$name" 2>/dev/null; then
    openssl verify -CAfile "$dir/ca.crt" -verify_ip "$name" "$dir/server.crt" >/dev/null || return 1
  else
    openssl verify -CAfile "$dir/ca.crt" -verify_hostname "$name" "$dir/server.crt" >/dev/null || return 1
  fi
  openssl x509 -in "$dir/server.crt" -checkend 0 -noout >/dev/null || return 1
  key_public="$(openssl pkey -in "$dir/server.key" -passin pass: -pubout 2>/dev/null)" || return 1
  cert_public="$(openssl x509 -in "$dir/server.crt" -pubkey -noout)" || return 1
  [[ -n "$key_public" && "$key_public" == "$cert_public" ]] || { relay_error '节点证书与私钥不匹配。'; return 1; }
}

generate_pki() {
  local dir="$1" name="$2" san
  validate_server_name "$name" || return 1
  [[ ! -e "$dir" ]] || { relay_error '证书生成目录必须是新目录。'; return 1; }
  mkdir -m 0700 "$dir"
  if python3 -c 'import ipaddress,sys;ipaddress.ip_address(sys.argv[1])' "$name" 2>/dev/null; then san="IP:$name"; else san="DNS:$name"; fi
  openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 730 -keyout "$dir/ca.key" -out "$dir/ca.crt" -subj '/CN=ServerWorkbench Relay CA' -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' -addext 'keyUsage=critical,keyCertSign,cRLSign' >/dev/null 2>&1
  openssl req -new -newkey rsa:3072 -nodes -sha256 -keyout "$dir/server.key" -out "$dir/server.csr" -subj "/CN=$name" >/dev/null 2>&1
  printf '%s\n' 'basicConstraints=critical,CA:FALSE' 'keyUsage=critical,digitalSignature,keyEncipherment' 'extendedKeyUsage=serverAuth' "subjectAltName=$san" > "$dir/server.ext"
  openssl x509 -req -sha256 -days 365 -in "$dir/server.csr" -CA "$dir/ca.crt" -CAkey "$dir/ca.key" -CAcreateserial -out "$dir/server.crt" -extfile "$dir/server.ext" >/dev/null 2>&1
  verify_pki "$dir" "$name"
  # CA signing material is never committed/exported/backed up on the relay.
  rm -f -- "$dir/ca.key" "$dir/ca.srl" "$dir/server.csr" "$dir/server.ext"
  chmod 0600 "$dir/server.key"
}

new_stage() {
  mkdir -p "$SWB_STATE_DIR"
  chmod 0700 "$SWB_STATE_DIR"
  printf '%s\n' serverworkbench-relay-v1 > "$SWB_STATE_DIR/.managed"
  TEMP_DIR="$(mktemp -d "$SWB_STATE_DIR/.stage-XXXXXXXX")"
  chmod 0700 "$TEMP_DIR"
}

download_frps() {
  local destination="$1" archive="$TEMP_DIR/frp.tar.gz" expected
  expected="$(archive_sha256 "$ARCH")"
  if ((TESTING)) && [[ -n "${SWB_RELAY_FIXTURE_ARCHIVE:-}" ]]; then
    cp -- "$SWB_RELAY_FIXTURE_ARCHIVE" "$archive"
  else
    curl --fail --show-error --location --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 180 --retry 2 --output "$archive" "https://github.com/fatedier/frp/releases/download/v$FRP_VERSION/frp_${FRP_VERSION}_linux_${ARCH}.tar.gz"
  fi
  [[ "$(sha256sum "$archive" | cut -d ' ' -f1)" == "$expected" ]] || die '官方 frp 压缩包 SHA256 不匹配，拒绝安装。'
  mkdir -m 0700 "$destination"
  python3 - "$archive" "$destination" "$FRP_VERSION" "$ARCH" <<'PY'
import pathlib,shutil,sys,tarfile
archive,dest,version,arch=sys.argv[1:]
with tarfile.open(archive,'r:gz') as t:
    for name in ('frps','LICENSE'):
        e=t.getmember(f'frp_{version}_linux_{arch}/{name}')
        if not e.isfile() or not 0<e.size<64*1024*1024: raise SystemExit('压缩包组件类型/大小无效。')
        with t.extractfile(e) as src,open(pathlib.Path(dest)/name,'xb') as out: shutil.copyfileobj(src,out)
PY
  chmod 0755 "$destination/frps"
  [[ "$("$destination/frps" --version)" == "$FRP_VERSION" ]] || die 'frps 版本探针失败。'
}

backup_current() {
  BACKUP_DIR="$(mktemp -d "$SWB_STATE_DIR/backup-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXXXX")"
  chmod 0700 "$BACKUP_DIR"
  HAD_CONFIG=0; HAD_BINARY=0; HAD_UNIT=0; HAD_RUNTIME=0; WAS_ACTIVE=0; WAS_ENABLED=0
  if [[ -d "$SWB_CONFIG_DIR" ]]; then cp -a -- "$SWB_CONFIG_DIR" "$BACKUP_DIR/config"; HAD_CONFIG=1; fi
  if [[ -f "$SWB_INSTALL_DIR/frps" ]]; then cp -a -- "$SWB_INSTALL_DIR/frps" "$BACKUP_DIR/frps"; HAD_BINARY=1; fi
  if [[ -f "$SWB_INSTALL_DIR/.managed" ]]; then
    mkdir -m 0700 "$BACKUP_DIR/runtime"
    local item
    for item in relay.sh lib .managed LICENSE-frp.txt; do
      [[ ! -e "$SWB_INSTALL_DIR/$item" ]] || cp -a -- "$SWB_INSTALL_DIR/$item" "$BACKUP_DIR/runtime/"
    done
    HAD_RUNTIME=1
  fi
  if [[ -f "$SWB_UNIT" ]]; then cp -a -- "$SWB_UNIT" "$BACKUP_DIR/service"; HAD_UNIT=1; fi
  if [[ -f "$SWB_WRAPPER" ]]; then cp -a -- "$SWB_WRAPPER" "$BACKUP_DIR/wrapper"; fi
  if service_cmd is-active --quiet "$SERVICE" 2>/dev/null; then WAS_ACTIVE=1; fi
  if service_cmd is-enabled --quiet "$SERVICE" 2>/dev/null; then WAS_ENABLED=1; fi
}

fix_owners() {
  chmod 0750 "$SWB_CONFIG_DIR"
  chmod 0600 "$SWB_CONFIG_DIR/frps.env" "$SWB_CONFIG_DIR/node.json" "$SWB_CONFIG_DIR/.managed"
  chmod 0640 "$SWB_CONFIG_DIR/frps.toml" "$SWB_CONFIG_DIR/server.crt" "$SWB_CONFIG_DIR/server.key" "$SWB_CONFIG_DIR/ca.crt"
  if ! ((TESTING)); then
    chown root:swb-frp "$SWB_CONFIG_DIR" "$SWB_CONFIG_DIR/frps.toml" "$SWB_CONFIG_DIR/server.crt" "$SWB_CONFIG_DIR/server.key" "$SWB_CONFIG_DIR/ca.crt"
    chown root:root "$SWB_CONFIG_DIR/frps.env" "$SWB_CONFIG_DIR/node.json" "$SWB_CONFIG_DIR/.managed"
  fi
}

ensure_account() {
  ((TESTING)) && return 0
  if getent group swb-frp >/dev/null; then verify_group_exclusive; fi
  if getent passwd swb-frp >/dev/null; then
    local row uid shell
    row="$(getent passwd swb-frp)"; uid="$(cut -d: -f3 <<< "$row")"; shell="$(cut -d: -f7 <<< "$row")"
    if ! [[ "$uid" =~ ^[0-9]+$ && ( "$shell" == */nologin || "$shell" == */false ) ]] || ((uid <= 0 || uid >= 1000)); then die '已有 swb-frp 不是专用系统禁登录账户，拒绝复用。'; fi
    getent group swb-frp >/dev/null || die '专用账户缺少同名组。'
  else
    getent group swb-frp >/dev/null || groupadd --system swb-frp
    useradd --system --gid swb-frp --no-create-home --shell /usr/sbin/nologin swb-frp
  fi
  verify_group_exclusive
  local group_id member_id group_memberships
  group_id="$(getent group swb-frp | cut -d: -f3)"
  [[ "$(getent passwd swb-frp | cut -d: -f4)" == "$group_id" ]] || die 'swb-frp 的主组不是专用组。'
  group_memberships="$(id -G swb-frp)" || die '无法确认专用账户的组成员关系。'
  for member_id in $group_memberships; do [[ "$member_id" == "$group_id" ]] || die 'swb-frp 加入了其他组，拒绝复用共享/特权账户。'; done
}

verify_group_exclusive() {
  local row group_id members name other_gid
  row="$(getent group swb-frp)"
  group_id="$(cut -d: -f3 <<< "$row")"; members="$(cut -d: -f4 <<< "$row")"
  if ! [[ "$group_id" =~ ^[0-9]+$ ]] || ((group_id <= 0 || group_id >= 1000)); then die 'swb-frp 不是专用系统组。'; fi
  [[ -z "$members" || "$members" == swb-frp ]] || die 'swb-frp 组包含其他成员，拒绝向共享组提供节点私钥。'
  while IFS=: read -r name _ _ other_gid _; do
    [[ "$other_gid" != "$group_id" || "$name" == swb-frp ]] || die '其他账户使用 swb-frp 作为主组，拒绝复用。'
  done < <(getent passwd)
}

install_manager() {
  mkdir -p "$SWB_INSTALL_DIR/lib" "$(dirname "$SWB_WRAPPER")" "$(dirname "$SWB_UNIT")"
  chmod 0755 "$SWB_INSTALL_DIR" "$SWB_INSTALL_DIR/lib"
  if [[ "$SWB_SOURCE_DIR" != "$SWB_INSTALL_DIR" ]]; then
    install -m 0755 "$SWB_SOURCE_DIR/relay.sh" "$SWB_INSTALL_DIR/relay.sh"
    install -m 0644 "$SWB_SOURCE_DIR/lib/common.sh" "$SWB_INSTALL_DIR/lib/common.sh"
    install -m 0644 "$SWB_SOURCE_DIR/lib/pins.sh" "$SWB_INSTALL_DIR/lib/pins.sh"
  fi
  printf '%s\n' serverworkbench-relay-v1 > "$SWB_INSTALL_DIR/.managed"
  printf '#!/usr/bin/env bash\n# Managed by serverworkbench-relay\nexec bash %q "$@"\n' "$SWB_INSTALL_DIR/relay.sh" > "$SWB_WRAPPER"
  chmod 0755 "$SWB_WRAPPER"
}

write_metadata() {
  local output="$1" binary="$2" ca="$3"
  python3 - "$output" "$SERVER" "$CONTROL" "$GAME" "$SERVER_NAME" "$FRP_VERSION" "$(sha256sum "$binary" | cut -d ' ' -f1)" "$(sha256sum "$ca" | cut -d ' ' -f1)" <<'PY'
import datetime,json,sys
out,host,control,game,name,version,binary,ca=sys.argv[1:]
with open(out,'x',encoding='utf-8') as f:
    json.dump({'managedBy':'serverworkbench-relay','schemaVersion':1,'serverAddress':host,'serverPort':int(control),
               'remotePort':int(game),'serverName':name,'frpVersion':version,'binarySha256':binary,'caSha256':ca,
               'updatedUtc':datetime.datetime.now(datetime.timezone.utc).isoformat()},f,ensure_ascii=False,indent=2)
    f.write('\n')
PY
}

atomic_file() {
  local source="$1" destination="$2" mode="$3" temporary
  reject_symlink_path "$destination"
  temporary="$(mktemp "$(dirname "$destination")/.swb-file-XXXXXXXX")"
  install -m "$mode" "$source" "$temporary"
  mv -f -- "$temporary" "$destination"
}

activate_service() {
  if ((NO_START)); then
    if ((TESTING)) || systemctl show-environment >/dev/null 2>&1; then service_cmd daemon-reload; fi
    note '文件已准备；--no-start 没有启动或启用中转服务。'
    return
  fi
  service_cmd daemon-reload
  service_cmd enable "$SERVICE" >/dev/null
  service_cmd restart "$SERVICE"
  service_cmd is-active --quiet "$SERVICE" || die '服务启动失败。'
  if ! ((TESTING)); then verify_service_ready; fi
}

verify_service_ready() {
  # Type=simple being active is insufficient: require this node's TLS identity.
  python3 - "$SERVICE" "$CONTROL" "$SWB_CONFIG_DIR/ca.crt" "$SERVER_NAME" <<'PY'
import socket,ssl,subprocess,sys,time
service,port,ca,name=sys.argv[1:]
context=ssl.create_default_context(cafile=ca)
deadline=time.monotonic()+12
while time.monotonic()<deadline:
    try:
        with socket.create_connection(('127.0.0.1',int(port)),timeout=1) as raw:
            with context.wrap_socket(raw,server_hostname=name): pass
        time.sleep(.3)
        if subprocess.run(['systemctl','is-active','--quiet',service],
                          stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0:
            print('本机 TLS 就绪检查通过；尚未验证公网连接。')
            raise SystemExit(0)
    except (OSError,ssl.SSLError):
        pass
    time.sleep(.25)
raise SystemExit('服务未通过本机 TLS 就绪检查；请检查端口占用、证书和本机 journalctl。')
PY
}

rollback() {
  note '提交失败，正在恢复先前配置；凭据和备份均保留。' >&2
  service_cmd stop "$SERVICE" >/dev/null 2>&1 || true
  if ! ((WAS_ENABLED)); then service_cmd disable "$SERVICE" >/dev/null 2>&1 || true; fi
  if ((HAD_CONFIG)); then
    local file
    for file in ca.crt server.crt server.key frps.toml frps.env node.json .managed; do
      [[ -f "$BACKUP_DIR/config/$file" ]] && cp -a -- "$BACKUP_DIR/config/$file" "$SWB_CONFIG_DIR/$file"
    done
    fix_owners
  else
    note "首次安装文件保留待检查：$SWB_CONFIG_DIR" >&2
  fi
  if ((HAD_BINARY)); then cp -a -- "$BACKUP_DIR/frps" "$SWB_INSTALL_DIR/frps"; fi
  if ((HAD_RUNTIME)); then
    local item
    for item in relay.sh lib .managed LICENSE-frp.txt; do
      [[ ! -e "$BACKUP_DIR/runtime/$item" ]] || cp -a -- "$BACKUP_DIR/runtime/$item" "$SWB_INSTALL_DIR/"
    done
  fi
  if [[ -f "$BACKUP_DIR/wrapper" ]]; then cp -a -- "$BACKUP_DIR/wrapper" "$SWB_WRAPPER"; fi
  if ((HAD_UNIT)); then
    cp -a -- "$BACKUP_DIR/service" "$SWB_UNIT"
  elif [[ -f "$SWB_UNIT" ]] && grep -q '^# Managed by serverworkbench-relay$' "$SWB_UNIT"; then
    cp -a -- "$SWB_UNIT" "$BACKUP_DIR/failed-new-service"
    rm -f -- "$SWB_UNIT"
  fi
  service_cmd daemon-reload >/dev/null 2>&1 || true
  if ((WAS_ENABLED)); then service_cmd enable "$SERVICE" >/dev/null 2>&1 || note '旧服务启用状态未能恢复。' >&2; fi
  if ((WAS_ACTIVE)); then service_cmd start "$SERVICE" >/dev/null 2>&1 || note '旧服务重启未成功，请查看本机 journalctl。' >&2; fi
  note "恢复备份：$BACKUP_DIR" >&2
}

cleanup() {
  local code=$?
  trap - EXIT
  set +e
  if ((code != 0 && ROLLBACK_REQUIRED)); then rollback; fi
  if [[ -n "$TEMP_DIR" && "$TEMP_DIR" == "$SWB_STATE_DIR"/.stage-* && -d "$TEMP_DIR" && ! -L "$TEMP_DIR" ]]; then rm -rf -- "$TEMP_DIR"; fi
  exit "$code"
}

open_firewall() {
  ((OPEN_FIREWALL)) || return 0
  ((TESTING)) && { note '测试模式不修改防火墙。'; return 0; }
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
    if ! ufw allow "$CONTROL/tcp" comment 'serverworkbench-relay control' || ! ufw allow "$GAME/tcp" comment 'serverworkbench-relay game'; then
      die '节点已部署，但 UFW 规则可能只添加了一部分。请在本机检查 ufw status；为保护既有规则，不自动删除端口规则。'
    fi
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    if ! firewall-cmd --permanent --add-port="$CONTROL/tcp" || ! firewall-cmd --permanent --add-port="$GAME/tcp" ||
       ! firewall-cmd --add-port="$CONTROL/tcp" || ! firewall-cmd --add-port="$GAME/tcp"; then
      die '节点已部署，但 firewalld 规则可能只添加了一部分。请在本机检查规则；为保护既有规则，不自动删除端口规则。'
    fi
  else
    die '--open-firewall 需要已启用的 UFW/firewalld；本工具不会自动启用防火墙或修改其他规则。'
  fi
}

secure_export_client() {
  python3 - "$1" "$SWB_CONFIG_DIR/ca.crt" "$SAVED_SERVER" "$SAVED_CONTROL" "$SAVED_GAME" "$SAVED_NAME" "$SAVED_CA_SHA" <<'PY'
import hashlib,json,os,pwd,stat,sys
out,ca,server,control,game,name,digest=sys.argv[1:]
if not out.startswith('/') or '\0' in out: raise SystemExit('导出目录必须是绝对路径。')
parts=[v for v in out.split('/') if v]
if not parts or any(v in ('.','..') for v in parts): raise SystemExit('导出目录无效。')
record={'schemaVersion':1,'managedBy':'serverworkbench-relay','serverAddress':server,
        'serverPort':int(control),'remotePort':int(game),'serverName':name,'caFile':'ca.crt','caSha256':digest,
        'token':'请在节点本地执行 sudo swb-relay show-token 后手动填写；此文件不含 Token',
        'instructions':'在开服工坊的 frp 穿透配置中手动填写；不要将本文件当成可执行配置导入。'}
public_ca=open(ca,'rb').read()
if hashlib.sha256(public_ca).hexdigest()!=digest: raise SystemExit('CA 文件已变化，拒绝导出。')
export_uid,export_gid=os.geteuid(),os.getegid()
sudo_uid,sudo_gid,sudo_user=os.environ.get('SUDO_UID',''),os.environ.get('SUDO_GID',''),os.environ.get('SUDO_USER','')
if os.geteuid()==0 and sudo_uid.isdigit() and sudo_gid.isdigit() and int(sudo_uid)>0:
    account=pwd.getpwuid(int(sudo_uid))
    if account.pw_name!=sudo_user: raise SystemExit('无法确认 sudo 调用用户，拒绝改变导出所有者。')
    export_uid,export_gid=int(sudo_uid),int(sudo_gid)
flags=os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW
parent=os.open('/',flags)
target=None
try:
    for part in parts[:-1]:
        try: child=os.open(part,flags,dir_fd=parent)
        except FileNotFoundError:
            os.mkdir(part,0o700,dir_fd=parent)
            child=os.open(part,flags,dir_fd=parent)
        os.close(parent);parent=child
    leaf=parts[-1]
    os.mkdir(leaf,0o700,dir_fd=parent)  # existing directories/symlinks are never reused
    target=os.open(leaf,flags,dir_fd=parent)
    info=os.fstat(target)
    if info.st_uid!=os.geteuid() or stat.S_IMODE(info.st_mode)&0o077: raise SystemExit('导出目录身份或权限已改变。')
    for file,payload in [('ca.crt',public_ca),('client.json',(json.dumps(record,ensure_ascii=False,indent=2)+'\n').encode())]:
        fd=os.open(file,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=target)
        with os.fdopen(fd,'wb') as f:
            f.write(payload)
            os.fchown(f.fileno(),export_uid,export_gid)
    os.fchown(target,export_uid,export_gid)
    final=os.stat(leaf,dir_fd=parent,follow_symlinks=False)
    if (final.st_dev,final.st_ino)!=(info.st_dev,info.st_ino): raise SystemExit('导出目录在写入期间被移动；未跟随替换目录，请检查目标路径。')
finally:
    if target is not None: os.close(target)
    os.close(parent)
PY
}

config_display() {
  load_saved
  printf '节点地址：%s\n控制端口：%s/TCP\n游戏端口：%s/TCP\n证书名称：%s\nCA 公钥：%s/ca.crt\nCA PEM SHA256：%s\nToken：已配置（执行 sudo swb-relay show-token 在本机终端查看）\n' "$SAVED_SERVER" "$SAVED_CONTROL" "$SAVED_GAME" "$SAVED_NAME" "$SWB_CONFIG_DIR" "$SAVED_CA_SHA"
  note '以上是配置值；服务运行/端口注册不代表公网已通过。游戏和存档仍在 Windows 电脑。'
}

deploy() {
  local mode="$1" reuse=0 token pki staged_config current_config
  check_existing_paths
  if [[ -f "$SWB_CONFIG_DIR/node.json" ]]; then
    load_saved; reuse=1
    SERVER="${SERVER:-$SAVED_SERVER}"; CONTROL="${CONTROL:-$SAVED_CONTROL}"; GAME="${GAME:-$SAVED_GAME}"; SERVER_NAME="${SERVER_NAME:-$SAVED_NAME}"
    [[ "$SERVER" == "$SAVED_SERVER" && "$CONTROL" == "$SAVED_CONTROL" && "$GAME" == "$SAVED_GAME" ]] || die '已有节点参数不同；不会通过重复安装修改地址或端口。请先备份并显式编辑节点配置。'
    if [[ "$mode" != renew ]]; then [[ "$SERVER_NAME" == "$SAVED_NAME" ]] || die '修改证书名称需要 renew --rotate-ca。'; fi
    if [[ "$mode" == install && -f "$SWB_INSTALL_DIR/frps" && -f "$SWB_UNIT" && "$(sha256sum "$SWB_INSTALL_DIR/frps" | cut -d ' ' -f1)" == "$SAVED_BINARY_SHA" ]]; then
      verify_pki "$SWB_CONFIG_DIR" "$SERVER_NAME"
      if ((DRY_RUN)); then note 'DRY RUN：现有节点参数与组件校验通过，没有修改任何文件或服务。'; return; fi
      note '现有安装校验通过；保留全部凭据和端口。'
      if ! ((NO_START)); then
        if ! service_cmd is-active --quiet "$SERVICE"; then activate_service
        elif ! ((TESTING)); then verify_service_ready; fi
      fi
      open_firewall
      config_display
      return
    fi
  else
    [[ "$mode" == install ]] || die '请先 install 安装节点。'
    CONTROL="${CONTROL:-7000}"; GAME="${GAME:-7777}"; SERVER_NAME="${SERVER_NAME:-kaifu-relay}"
    if [[ -z "$SERVER" ]]; then
      if [[ -t 0 ]]; then read -r -p '请输入服务器公网 IP 或域名：' SERVER; else die '首次安装请指定 --server 公网IP或域名。'; fi
    fi
  fi
  validate_options "$SERVER" "$CONTROL" "$GAME" "$SERVER_NAME" || die '安装参数无效。'
  if ((DRY_RUN)); then
    printf 'DRY RUN：%s frp %s；节点 %s；控制 TCP%s；游戏 TCP%s；证书名 %s；服务启动=%s；防火墙修改=%s\n' "$mode" "$FRP_VERSION" "$SERVER" "$CONTROL" "$GAME" "$SERVER_NAME" "$((!NO_START))" "$OPEN_FIREWALL"
    return
  fi
  ensure_account
  new_stage
  download_frps "$TEMP_DIR/release"
  pki="$TEMP_DIR/pki"
  if ((reuse)) && [[ "$mode" != renew ]]; then
    mkdir -m 0700 "$pki"
    cp -- "$SWB_CONFIG_DIR/ca.crt" "$SWB_CONFIG_DIR/server.crt" "$SWB_CONFIG_DIR/server.key" "$pki/"
    token="$(read_token "$SWB_CONFIG_DIR/frps.env")"
    verify_pki "$pki" "$SERVER_NAME"
  else
    generate_pki "$pki" "$SERVER_NAME"
    if ((reuse)); then token="$(read_token "$SWB_CONFIG_DIR/frps.env")"; else token="$(openssl rand -hex 32)"; fi
  fi
  validate_token "$token"
  staged_config="$TEMP_DIR/config"
  mkdir -m 0700 "$staged_config"
  cp -- "$pki/ca.crt" "$pki/server.crt" "$pki/server.key" "$staged_config/"
  printf 'SWB_FRP_TOKEN=%s\n' "$token" > "$staged_config/frps.env"
  current_config="$SWB_CONFIG_DIR"; SWB_CONFIG_DIR="$staged_config"
  render_frps "$CONTROL" "$GAME" > "$staged_config/frps.toml"
  SWB_FRP_TOKEN="$token" "$TEMP_DIR/release/frps" verify -c "$staged_config/frps.toml" >/dev/null
  SWB_CONFIG_DIR="$current_config"
  render_frps "$CONTROL" "$GAME" > "$staged_config/frps.toml"
  write_metadata "$staged_config/node.json" "$TEMP_DIR/release/frps" "$staged_config/ca.crt"
  printf '%s\n' serverworkbench-relay-v1 > "$staged_config/.managed"
  render_service > "$TEMP_DIR/service"
  backup_current
  ROLLBACK_REQUIRED=1
  mkdir -p "$SWB_CONFIG_DIR"
  install_manager
  local file
  for file in ca.crt server.crt server.key frps.toml frps.env node.json .managed; do atomic_file "$staged_config/$file" "$SWB_CONFIG_DIR/$file" 0600; done
  fix_owners
  atomic_file "$TEMP_DIR/release/frps" "$SWB_INSTALL_DIR/frps" 0755
  atomic_file "$TEMP_DIR/release/LICENSE" "$SWB_INSTALL_DIR/LICENSE-frp.txt" 0644
  atomic_file "$TEMP_DIR/service" "$SWB_UNIT" 0644
  activate_service
  ROLLBACK_REQUIRED=0
  unset token
  open_firewall
  if [[ "$mode" == renew ]]; then note 'CA 已显式轮换。Windows 必须重新导入新 ca.crt 并填写原 Token；旧 CA 不再适用。'; fi
  note "完成。备份：$BACKUP_DIR"
  note "云安全组和主机防火墙需要允许 TCP$CONTROL、TCP$GAME；本地电脑需能连接 TCP$CONTROL。"
  config_display
}

main() {
  local command="${1:-help}"
  [[ $# -eq 0 ]] || shift
  while (($#)); do
    case "$1" in
      --server|--control-port|--game-port|--server-name|--output)
        (($# >= 2)) || die "缺少 $1 参数。"
        case "$1" in --server) SERVER="$2" ;; --control-port) CONTROL="$2" ;; --game-port) GAME="$2" ;; --server-name) SERVER_NAME="$2" ;; --output) EXPORT_OUTPUT="$2" ;; esac
        shift 2 ;;
      --no-start) NO_START=1; shift ;;
      --open-firewall) OPEN_FIREWALL=1; shift ;;
      --no-install-deps) NO_INSTALL_DEPS=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --rotate-ca) ROTATE_CA=1; shift ;;
      --help|-h) usage; return ;;
      *) die "未知选项：$1" ;;
    esac
  done
  case "$command" in help|--help|-h) usage; return ;; version|--version) printf '%s\n' "$SWB_RELAY_VERSION (frp $FRP_VERSION)"; return ;; install|upgrade|renew|status|config|show-token|export-client|uninstall) ;; *) die "未知命令：$command" ;; esac
  init_paths
  root_required
  platform_check
  if [[ "$command" == renew ]]; then ((ROTATE_CA)) || die 'renew 必须显式指定 --rotate-ca；这会要求 Windows 重新导入 CA。'; fi
  if ((DRY_RUN)); then
    [[ "$command" == install || "$command" == upgrade || "$command" == renew ]] || die '--dry-run 仅适用于 install/upgrade/renew。'
    command -v python3 >/dev/null || die 'dry-run 参数校验需要 Python3；未安装任何依赖。'
  else
    dependencies "$command"
    check_existing_paths
    mkdir -p "$SWB_STATE_DIR"
    chmod 0700 "$SWB_STATE_DIR"
    printf '%s\n' serverworkbench-relay-v1 > "$SWB_STATE_DIR/.managed"
    exec 9> "$SWB_STATE_DIR/manager.lock"
    flock -n 9 || die '另一个节点管理操作正在运行。'
    trap cleanup EXIT
    umask 077
  fi
  case "$command" in
    install|upgrade|renew) deploy "$command" ;;
    config) config_display ;;
    show-token)
      load_saved
      [[ -t 1 ]] || die 'show-token 只允许在交互终端显示，不写入管道/日志文件。'
      read_token "$SWB_CONFIG_DIR/frps.env" ;;
    export-client)
      load_saved
      local out
      out="${EXPORT_OUTPUT:-$SWB_STATE_DIR/client-export-$(date -u +%Y%m%dT%H%M%SZ)}"
      reject_symlink_path "$out"
      [[ ! -e "$out" ]] || die '导出目标必须是新目录。'
      secure_export_client "$out"
      note "已导出 CA 公钥与无 Token 的填写说明：$out" ;;
    status)
      load_saved
      if service_cmd is-active --quiet "$SERVICE"; then note 'systemd：运行中（不代表公网可达）'; else note 'systemd：未运行'; fi
      config_display ;;
    uninstall)
      load_saved
      local unit_load_state
      unit_load_state="$(service_cmd show --property=LoadState --value "$SERVICE")" || die '无法确认服务加载状态，保留组件。'
      [[ "$unit_load_state" == loaded || "$unit_load_state" == not-found ]] || die "服务加载状态异常（$unit_load_state），保留组件。"
      if [[ ! -f "$SWB_UNIT" && ! -f "$SWB_INSTALL_DIR/frps" ]]; then
        if service_cmd is-active --quiet "$SERVICE"; then
          service_cmd stop "$SERVICE" >/dev/null 2>&1 || die '服务文件虽已移除，但运行进程未能停止。'
          if service_cmd is-active --quiet "$SERVICE"; then die '服务仍处于运行状态。'; fi
        fi
        if service_cmd is-enabled --quiet "$SERVICE"; then
          service_cmd disable "$SERVICE" >/dev/null 2>&1 || die '未能清除服务自启动状态。'
          if service_cmd is-enabled --quiet "$SERVICE"; then die '服务仍启用自启动。'; fi
        fi
        note '服务文件和 frps 二进制已移除；配置和备份仍保留。'
        return
      fi
      backup_current
      if [[ "$unit_load_state" != not-found ]] || service_cmd is-active --quiet "$SERVICE"; then
        service_cmd stop "$SERVICE" >/dev/null 2>&1 || die '无法确认服务已停止，服务文件和二进制均保留。'
      fi
      if service_cmd is-active --quiet "$SERVICE"; then die '服务仍处于运行状态，拒绝移除程序。'; fi
      if [[ "$unit_load_state" != not-found ]] || service_cmd is-enabled --quiet "$SERVICE"; then
        service_cmd disable "$SERVICE" >/dev/null 2>&1 || die '无法停用服务自启动，保留服务文件和二进制。'
      fi
      if service_cmd is-enabled --quiet "$SERVICE"; then die '服务仍启用自启动，拒绝移除程序。'; fi
      [[ ! -f "$SWB_UNIT" ]] || rm -f -- "$SWB_UNIT"
      if [[ -f "$SWB_INSTALL_DIR/frps" ]]; then mv -- "$SWB_INSTALL_DIR/frps" "$BACKUP_DIR/frps-uninstalled"; fi
      service_cmd daemon-reload >/dev/null 2>&1 || true
      note "已停用并移除服务与 frps 二进制；配置、凭据、管理命令、专用账户及备份保留：$BACKUP_DIR" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
