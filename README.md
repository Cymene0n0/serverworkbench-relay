# ServerWorkbench Relay · 开服工坊中转节点

在有公网 IPv4 的 Linux 主机上安装 frps，让你的 Windows 电脑继续运行游戏和保存世界。适配开服工坊 ServerWorkbench 的 frp 配置窗口，默认转发 Terraria / tModLoader 的 TCP7777。

```text
朋友客户端 ── 公网IP:7777 ── Linux frps ── TLS 隧道 ── 你电脑的 frpc ── 本机游戏:7777
                                      ↑
                         你电脑主动连接控制端口 TCP7000
```

## 一条指令安装

要求：Ubuntu 22.04 / 24.04 或 Debian 12+，systemd，amd64 / arm64，root 或 sudo，以及可被朋友访问的公网 IPv4。把命令中的 `YOUR_PUBLIC_IP` 替换成服务器公网 IPv4 或可用域名。

```bash
curl -fsSL https://raw.githubusercontent.com/Cymene0n0/serverworkbench-relay/main/install.sh | sudo bash -s -- --server YOUR_PUBLIC_IP
```

引导器先下载并核对管理脚本 SHA256，再执行安装。发布引导器固定管理脚本的提交与摘要；进一步固定引导器本身的方法见 [发行记录](CHANGELOG.md)。首次安装会自动：

1. 检查 Linux、CPU 和 systemd；只在缺依赖时使用系统 apt 源安装所需组件。
2. 从 frp 官方发布下载固定的 **0.71.1**，核对内置 SHA256，只提取 frps 与许可证。
3. 创建独立的 `swb-frp` 无登录账户、随机 Token、私有 CA 和节点证书。
4. 丢弃签发所用的 CA 私钥，仅保留 CA 公钥和受限的节点私钥。
5. 安装受 systemd 管理的服务，通过本节点 CA 和证书名称校验本机 TLS 连接，再输出 Windows 软件的填写信息。

证书验证名称默认 `kaifu-relay`，它是私有 CA 证书中的身份名称；连接地址仍填实际公网 IP。无需为这个验证名称购买或解析域名。

### 端口与云安全组

| 端口 | 用途 | 在哪里放行 |
|---|---|---|
| TCP7000 | 你的电脑连接 frps 控制端口 | 云安全组和 Linux 防火墙 |
| TCP7777 | 朋友连接游戏的公网端口 | 云安全组和 Linux 防火墙 |

默认安装不更改防火墙。若主机已经启用 UFW 或 firewalld，可显式选择只添加上述端口规则：

```bash
curl -fsSL https://raw.githubusercontent.com/Cymene0n0/serverworkbench-relay/main/install.sh | sudo bash -s -- --server YOUR_PUBLIC_IP --open-firewall
```

不会替你修改云平台安全组，也不会启用/关闭整个防火墙。云厂商的公网带宽和流量额度由你管理。

### 常用安装选项

```bash
# 更改端口；控制和游戏端口必须不同，且均 >=1024
sudo bash relay.sh install --server YOUR_PUBLIC_IP --control-port 7000 --game-port 7777

# 只准备文件，不启动服务
sudo bash relay.sh install --server YOUR_PUBLIC_IP --no-start

# 只检查参数和计划，不下载、安装依赖或修改系统
sudo bash relay.sh install --server YOUR_PUBLIC_IP --dry-run
```

第一次安装必须提供 `--server`。不会猜测出口代理 IP 或悄悄使用公共节点。已管理节点若指定不同地址、端口或证书名称，会拒绝覆盖；需要修改时先保存备份并明确迁移。

## 在 Windows 开服工坊中填写

先在 Linux 上查看非秘密配置，再导出 CA 公钥：

```bash
sudo swb-relay config
sudo swb-relay export-client --output "$HOME/swb-client"
```

导出目录必须不存在。导出只有 `ca.crt` 和 `client.json` 填写说明，没有 Token 或私钥。目前开服工坊需要手动填写，不能直接导入这个 JSON。

通过 `sudo` 导出时，新建目录和其中两份公开文件会自动交给原 SSH 账户读取，可使用 scp/SFTP 下载。直接用 root 导出时仍归 root 所有。建议使用上面的个人主目录路径。

在服务器的交互终端单独查看 Token：

```bash
sudo swb-relay show-token
```

此命令不会向管道输出认证值；请将值填入软件，避免放进聊天、截图或仓库。不要尝试用 `show-token > token.txt` 绕过终端限制。

打开“联机指引 → frp 内网穿透 → 穿透配置”：

| 软件字段 | 对应值 |
|---|---|
| 中转节点地址 | 安装时的公网 IPv4 / 域名 |
| 中转控制端口 | 默认7000 |
| 朋友连接的端口 | 默认7777 |
| 证书中的节点名称 | 默认 `kaifu-relay` |
| 可信 CA 证书 | 导出的单张 `ca.crt` |
| Token | `sudo swb-relay show-token` 显示的值 |

先启动本机游戏，等待服务端就绪，再单独点击“启动穿透”。朋友使用 Linux 的公网 IPv4 和7777端口加入，并使用相同游戏、加载器和 Mod 版本。你自己的电脑需要保持开机联网。

“systemd运行”“代理已注册”都不代表公网玩家已经可以加入。必须从异地进行有效载荷或实际游戏客户端测试。停止游戏或退出管理器会停止对应穿透。

## 管理命令

```bash
sudo swb-relay status
sudo journalctl -u serverworkbench-relay.service -n 80 --no-pager
sudo systemctl restart serverworkbench-relay.service
sudo swb-relay upgrade
sudo swb-relay uninstall
```

- 重复安装、`upgrade`：重装仓库固定的上游版本，保留 Token、CA、端口和配置；不会自动追最新版。
- `uninstall`：停止并移除服务和活动 frps，保留配置、凭据、管理命令、专用账户及备份，便于恢复。它不会删除游戏，也不会自动删除防火墙规则或云安全组规则。
- 安装/升级失败：尝试恢复受管理文件和原服务状态；备份目录保留用于人工恢复。系统 apt 安装的依赖不会自动卸载。
- 可选的防火墙步骤失败时，节点可能已部署，端口规则可能只添加了一部分；命令会返回失败并明确提示。先执行 `status` 检查，再核对防火墙。已有规则不会被自动删除。

### 证书续期

节点证书默认有效365天。由于 CA 私钥在签发后已丢弃，续期会创建新 CA，必须明确执行：

```bash
sudo swb-relay renew --rotate-ca
```

随后重新导出 `ca.crt`，在 Windows 软件内重新选择并保存；证书验证名称、Token 和端口保持原值。续期会使仍信任旧 CA 的客户端暂时无法重连，需安排停机窗口。安装和普通升级不会暗中轮换 CA 或 Token。

## 文件位置

| 路径 | 内容 |
|---|---|
| `/etc/serverworkbench-relay` | 证书、只含环境变量引用的 TOML、root 专用 Token 环境文件、节点元数据 |
| `/usr/local/lib/serverworkbench-relay` | frps 和管理脚本 |
| `/usr/local/bin/swb-relay` | 管理命令入口 |
| `/var/lib/serverworkbench-relay/backup-*` | 受限的维护备份 |
| `/etc/systemd/system/serverworkbench-relay.service` | systemd 单元 |

不要公开这些系统目录。仅 `export-client` 的公钥说明包适合拿回 Windows，Token 单独填写。

## 验证与边界

测试命令与实测报告见 [tests/README.md](tests/README.md) 和 [docs/测试报告.md](docs/测试报告.md)。CI 配置覆盖 Ubuntu22.04/24.04 与 Debian12；是否已运行通过以 Actions 结果为准。

本项目负责 TCP 中转，默认不开放管理面板、HTTP虚拟主机、SSH网关或其他代理。它不提供免费公网主机，不使 IPv4-only 朋友自动获得 IPv6，也不配置你的游戏客户端或云账户。原开服工坊保持 Windows 管理器框架，本仓库是独立 Linux 部署工具。

## 许可证与上游

管理脚本使用 [MIT](LICENSE)；按需下载的 frp 使用 [Apache-2.0](LICENSE-frp.txt)。见 [第三方说明](THIRD-PARTY-NOTICES.md) 和 [安全边界](SECURITY.md)。

- [frp 官方仓库](https://github.com/fatedier/frp)
- [frp TLS 身份校验](https://gofrp.org/en/docs/features/common/network/network-tls/)
- [frp systemd 部署](https://gofrp.org/en/docs/setup/systemd/)
