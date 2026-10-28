# vps-vpn：一键重装 Xray + HY2 + WARP 的 VPN

给纯 IPv6 VPS 用的自建 VPN 一键安装包。VPS 崩了、换了新机器，一条命令就能重装回原来的架构，装完运行 `nodes` 即输出新的节点链接，导入 v2rayNG 就能用。

## 架构

```
手机（v2rayNG）
  │  TCP 443：VLESS + gRPC + TLS（serviceName=gun，allowInsecure=1）
  │  UDP 443：Hysteria2（自签证书，sni=www.example.com，insecure=1）
  ▼
VPS（纯 IPv6，Xray + HY2 同占 443 端口，TCP/UDP 不冲突）
  │  IPv4 出口：wgcf/WARP（默认路由，IPv6 走原生）
  ▼
互联网（出口国家 = WARP 出口所在地，例如德国）
```

## 文件说明

| 文件 | 作用 |
|---|---|
| `install.sh` | 一键安装主脚本（幂等，可重跑） |
| `xray/config.json.template` | Xray 配置模板（`__XRAY_UUID__` 由安装时生成并替换） |
| `hysteria/config.yaml.template` | HY2 配置模板（`__HY2_PASSWORD__` 由安装时生成并替换） |
| `nodes/nodes` | 链接输出工具：读 Xray UUID、HY2 密码、公网 IPv6、`/etc/node-name`，输出两条节点链接 |
| `uninstall.sh` | 卸载（停服务、删配置，客户端链接随即失效） |
| `.gitignore` | 防止误提交密钥与真实配置 |

## 一键安装（新 VPS 恢复用）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/leon0503/vps-vpn/main/install.sh)
```

装完脚本会自动运行 `nodes` 输出两条链接。以后随时想看链接，SSH 上去运行 `nodes` 即可。

改节点名前缀（例如新 VPS 在日本）：

```bash
NODE_NAME=日本 bash <(curl -fsSL https://raw.githubusercontent.com/leon0503/vps-vpn/main/install.sh)
```

或装完后改：

```bash
echo 日本 > /etc/node-name
nodes
```

## 恢复流程（VPS 崩了怎么办）

1. 买/开一台新 VPS（纯 IPv6 也行，跟原来同一家或别家都行）。
2. SSH 上去，用 root 跑上面那条一键命令。
3. 把新输出的两条链接导入 v2rayNG（旧链接失效是正常的，因为 UUID、密码、IPv6 都变了）。
4. 手机连上后访问 `ip.sb` 验证出口所在地，YouTube 能打开即为全通。

## 设计要点（都是原机踩过的坑）

- **幂等复用**：重跑 `install.sh` 不会换 UUID/密码/证书，已导入的客户端不受影响；只有全新机器才会生成新的。
- **端口复用**：Xray 走 TCP 443，HY2 走 UDP 443，互不冲突。
- **WARP 出口靠默认路由**：`wgcf.conf` 里不要加 `Table=off`，否则 Xray 出口会断；IPv4 默认走 wgcf，IPv6 走原生。
- **TCPMSS 钳制**：wgcf 配置里有 TCPMSS 1200 的 PostUp/PreDown，解决小包/握手问题。
- **MTU 1280**：wgcf 配置 MTU 固定 1280。
- **证书权限**：HY2 曾因证书权限起不来，安装脚本里显式修了 `755/644/600`，并按 systemd 的 `User=` 归属。
- **allowInsecure**：Xray 与 HY2 都用自签证书，客户端跳过验证（v2rayNG 里 allowInsecure=1 / insecure=1），所以证书不用公开可信也能连通；SNI 不影响连通。
- **wgcf 失败不中断**：如果新 VPS 上 wgcf 注册失败（例如 Cloudflare API 不通），脚本会警告但继续，Xray/HY2 仍可用，只是出口变成 VPS 原生 IP。

## 安全说明

- **仓库里没有任何密钥**：UUID、HY2 密码、证书私钥、wgcf 私钥全部在安装时本机生成，绝不进 GitHub（`.gitignore` 已挡住）。
- 因此仓库可以设为 **Public**，一键命令才能免认证下载；设为 Private 的话下载要带 token，反而麻烦。
- 千万别把 `/etc/wireguard/wgcf.conf`、`/usr/local/etc/xray/config.json`、`/etc/hysteria/config.yaml` 的真实内容贴到公开处。

## 不包含什么（原机的其他东西，需另行设置）

- **wg0（WireGuard 服务端）**：原机只给了方案、未确认搭通，所以没放进本项目；需要的话后续可加一个模块。
- **原机 crontab**：acme.sh、warp-go/warp-svc 定时重启、每天北京时间凌晨 4 点重启（`0 20 * * * /sbin/reboot`，UTC 20:00）、`@reboot` 的 WARP-UP.sh，这些是原机的运维任务，重装后如需可另行添加。
- **公开可信证书**：重装默认用自签证书（客户端跳过验证，完全可用）；如需根治证书问题，后续再上 acme.sh。

## 常见问题

- **HY2 起不来**：先看 `journalctl -u hysteria-server`，大概率是证书权限，按安装脚本里的 `chmod 755 /etc/hysteria`、`chmod 644 cert.crt`、`chmod 600 cert.key` 修。
- **VLESS 与 HY2 选哪个**：都导入，日常用哪个顺手用哪个；HY2 在弱网/丢包下通常更稳，VLESS 兼容性更广。
- **Xray 证书想换公开可信的**：后续用 acme.sh 给域名申请证书，替换 `/usr/local/etc/xray/cert.crt` 与 `cert.key` 后 `systemctl restart xray` 即可，客户端不用改（allowInsecure 本来就跳过验证）。
