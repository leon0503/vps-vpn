#!/bin/bash
# vps-vpn 一键安装脚本
# 架构：Xray VLESS+gRPC+TLS（TCP 443）+ Hysteria2（UDP 443）+ wgcf/WARP 出口 + nodes 链接输出工具
#
# 新 VPS 上一条命令（先把下面 REPO 改成你的仓库，推到 GitHub 后才能用）：
#   bash <(curl -fsSL https://raw.githubusercontent.com/REPO/main/install.sh)
# 也可先 git clone 再 sudo ./install.sh（会优先用本地模板文件）。
#
# 特点：
#   - 幂等，可重跑；已存在的 UUID/密码/证书会被复用，不会让已导入的客户端失效。
#   - 端口复用：Xray 用 TCP 443，HY2 用 UDP 443，两者不冲突。
#   - WARP 出口靠 wgcf 默认路由（wgcf.conf 里不要 Table=off，否则断 Xray 出口）。
#
# 安全：
#   - 本脚本不在任何地方写死密钥；UUID、HY2 密码、证书、wgcf 私钥均在安装时本机生成。
#   - 这些生成物绝不提交到 GitHub（见 .gitignore），仓库公开也安全。
set -e

# ============ 可改变量（上传 GitHub 前先改 REPO） ============
REPO="leon0503/vps-vpn"   # ← 改成你的 GitHub 用户名/仓库名，例如 Nor/vps-vpn
BRANCH="main"
NODE_NAME="${NODE_NAME:-德国}"              # 节点名前缀，可用环境变量覆盖：NODE_NAME=日本 sudo ./install.sh
XRAY_SNI="${XRAY_SNI:-eu.riven.dpdns.org}"  # Xray TLS 的 SNI；客户端 allowInsecure=1，不验证证书，改不改都不影响连通
# ============================================================

RAW_BASE="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo .)"

if [ "$REPO" = "YOUR_USERNAME/vps-vpn" ]; then
  echo "错误：请先把 install.sh 顶部的 REPO 改成你的 GitHub 仓库（YOUR_USERNAME/vps-vpn 是占位符）" >&2
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root 运行（或 sudo ./install.sh）" >&2
  exit 1
fi

# 取文件：优先用脚本旁边的本地文件（git clone 模式），否则从 GitHub 下载
fetch_file() {
  local rel="$1" dest="$2"
  if [ -f "${SCRIPT_DIR}/${rel}" ]; then
    cp "${SCRIPT_DIR}/${rel}" "$dest"
  else
    curl -fsSL "${RAW_BASE}/${rel}" -o "$dest" || {
      echo "错误：下载 ${rel} 失败，请检查 REPO/分支/网络" >&2
      exit 1
    }
  fi
}

echo "==> 1/6 安装依赖（curl/wget/openssl/python3/iproute2/iptables）"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || true
apt-get install -y -qq curl wget unzip openssl python3 iproute2 iptables > /dev/null

echo "==> 2/6 安装 Xray（VLESS + gRPC + TLS，TCP 443）"
if [ ! -x /usr/local/bin/xray ]; then
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi
mkdir -p /usr/local/etc/xray
# UUID：已有则复用，否则生成
if [ -f /usr/local/etc/xray/config.json ]; then
  XRAY_UUID="$(python3 -c "import json; print(json.load(open('/usr/local/etc/xray/config.json'))['inbounds'][0]['settings']['clients'][0]['id'])" 2>/dev/null || grep -oP '"id":\s*"\K[^"]+' /usr/local/etc/xray/config.json | head -n1 || true)"
fi
if [ -z "${XRAY_UUID:-}" ]; then
  XRAY_UUID="$(cat /proc/sys/kernel/random/uuid)"
  echo "生成新的 Xray UUID"
else
  echo "复用已有 Xray UUID（客户端不用重新导入）"
fi
# 证书：已有则复用，否则自签（CN=SNI；客户端 allowInsecure=1，不验证）
if [ ! -f /usr/local/etc/xray/cert.crt ] || [ ! -f /usr/local/etc/xray/cert.key ]; then
  openssl req -x509 -newkey rsa:2048 -keyout /usr/local/etc/xray/cert.key -out /usr/local/etc/xray/cert.crt -days 3650 -nodes -subj "/CN=${XRAY_SNI}" >/dev/null 2>&1
  chmod 644 /usr/local/etc/xray/cert.crt
  chmod 600 /usr/local/etc/xray/cert.key
  echo "生成 Xray 自签证书（CN=${XRAY_SNI}）"
fi
# 写配置
fetch_file "xray/config.json.template" /tmp/xray_config.json
sed -e "s/__XRAY_UUID__/${XRAY_UUID}/g" /tmp/xray_config.json > /usr/local/etc/xray/config.json
python3 -c "import json; json.load(open('/usr/local/etc/xray/config.json'))" && echo "Xray 配置 JSON 校验通过"
systemctl enable xray >/dev/null 2>&1 || true
systemctl restart xray
sleep 2
systemctl is-active --quiet xray && echo "Xray 运行中" || { echo "Xray 启动失败，请看 journalctl -u xray" >&2; exit 1; }

echo "==> 3/6 安装 Hysteria2（UDP 443）"
if ! systemctl list-unit-files 2>/dev/null | grep -q '^hysteria-server'; then
  bash <(curl -fsSL https://get.hy2.sh/)
fi
mkdir -p /etc/hysteria
# 密码：已有则复用，否则随机生成
if [ -f /etc/hysteria/config.yaml ]; then
  HY2_PASS="$(awk '/^[[:space:]]*password:/ {print $2; exit}' /etc/hysteria/config.yaml | tr -d '"'\''')"
fi
if [ -z "${HY2_PASS:-}" ]; then
  HY2_PASS="$(openssl rand -hex 16)"
  echo "生成新的 HY2 密码"
else
  echo "复用已有 HY2 密码（客户端不用重新导入）"
fi
# 证书：已有则复用，否则自签（CN=www.example.com，与原机一致）
if [ ! -f /etc/hysteria/cert.crt ] || [ ! -f /etc/hysteria/cert.key ]; then
  openssl req -x509 -newkey rsa:2048 -keyout /etc/hysteria/cert.key -out /etc/hysteria/cert.crt -days 3650 -nodes -subj "/CN=www.example.com" >/dev/null 2>&1
  echo "生成 HY2 自签证书（CN=www.example.com）"
fi
# 权限（原机曾因证书权限导致服务起不来，这里显式修好）
chmod 755 /etc/hysteria
chmod 644 /etc/hysteria/cert.crt
chmod 600 /etc/hysteria/cert.key
SVC_USER="$(systemctl show -p User --value hysteria-server 2>/dev/null || true)"
if [ -n "$SVC_USER" ]; then chown -R "$SVC_USER" /etc/hysteria; fi
fetch_file "hysteria/config.yaml.template" /tmp/hy2_config.yaml
sed -e "s/__HY2_PASSWORD__/${HY2_PASS}/g" /tmp/hy2_config.yaml > /etc/hysteria/config.yaml
systemctl enable hysteria-server >/dev/null 2>&1 || true
systemctl restart hysteria-server
sleep 2
systemctl is-active --quiet hysteria-server && echo "HY2 运行中" || { echo "HY2 启动失败，请看 journalctl -u hysteria-server（先查证书权限）" >&2; exit 1; }

echo "==> 4/6 安装 wgcf/WARP（IPv4 出口；失败不中断，后面两步照常）"
set +e
if ! command -v wgcf >/dev/null 2>&1; then
  WGCF_TAG="$(curl -fsSL https://api.github.com/repos/ViRb3/wgcf/releases/latest 2>/dev/null | grep -oP '"tag_name":\s*"\K[^"]+' | head -n1)"
  [ -z "$WGCF_TAG" ] && WGCF_TAG="v2.2.19"
  ARCH="$(uname -m)"; [ "$ARCH" = "x86_64" ] && ARCH="amd64"; [ "$ARCH" = "aarch64" ] && ARCH="arm64"
  curl -fsSL "https://github.com/ViRb3/wgcf/releases/download/${WGCF_TAG}/wgcf_${WGCF_TAG#v}_linux_${ARCH}" -o /usr/local/bin/wgcf
  chmod +x /usr/local/bin/wgcf 2>/dev/null || true
fi
if [ ! -f /etc/wireguard/wgcf.conf ]; then
  cd /tmp && wgcf register --accept-tos >/dev/null 2>&1 && wgcf generate >/dev/null 2>&1
  if [ -f /tmp/wgcf-profile.conf ]; then
    mkdir -p /etc/wireguard
    cp /tmp/wgcf-profile.conf /etc/wireguard/wgcf.conf
    cp /tmp/wgcf-account.toml /etc/wireguard/wgcf-account.toml 2>/dev/null || true
    chmod 600 /etc/wireguard/wgcf.conf /etc/wireguard/wgcf-account.toml 2>/dev/null || true
    # 关键：不要 Table=off（会断 Xray 出口）；MTU 1280；TCPMSS 1200 钳制
    sed -i '/^Table\s*=/d' /etc/wireguard/wgcf.conf
    grep -q '^MTU' /etc/wireguard/wgcf.conf || sed -i '/^\[Interface\]/a MTU = 1280' /etc/wireguard/wgcf.conf
    # PostUp/PreDown 必须插在 [Interface] 段内（[Peer] 之前），不能追加到文件末尾
    if ! grep -q 'TCPMSS' /etc/wireguard/wgcf.conf; then
      python3 - <<'PYEOF'
p = '/etc/wireguard/wgcf.conf'
s = open(p).read()
clamp = (
  "PostUp = iptables -t mangle -I POSTROUTING -o wgcf -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200\n"
  "PostUp = ip6tables -t mangle -I POSTROUTING -o wgcf -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200\n"
  "PreDown = iptables -t mangle -D POSTROUTING -o wgcf -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200\n"
  "PreDown = ip6tables -t mangle -D POSTROUTING -o wgcf -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200\n"
)
if 'TCPMSS' not in s:
    s = s.replace('[Peer]', clamp + '[Peer]', 1)
    open(p, 'w').write(s)
PYEOF
    fi
    systemctl enable wg-quick@wgcf >/dev/null 2>&1 || true
    systemctl restart wg-quick@wgcf
    sleep 3
    wg show wgcf >/dev/null 2>&1 && echo "wgcf 已启动（IPv4 走 WARP，IPv6 走原生）" || echo "警告：wgcf 未能启动，Xray/HY2 仍可用（出口为 VPS 原生 IP），可稍后手动 systemctl status wg-quick@wgcf 排查"
  else
    echo "警告：wgcf 注册/生成失败，跳过 WARP（Xray/HY2 仍可用，出口为 VPS 原生 IP）"
  fi
else
  echo "复用已有 /etc/wireguard/wgcf.conf"
  systemctl enable wg-quick@wgcf >/dev/null 2>&1 || true
  systemctl restart wg-quick@wgcf || true
fi
cd - >/dev/null 2>&1 || true
set -e

echo "==> 5/6 安装 nodes 链接输出工具"
fetch_file "nodes/nodes" /usr/local/bin/nodes
chmod +x /usr/local/bin/nodes
echo -n "$NODE_NAME" > /etc/node-name
echo "节点名前缀：${NODE_NAME}（改名：echo 新名字 > /etc/node-name，再运行 nodes）"

# 清理 /tmp 里含密钥的临时文件（正式配置已在 /etc 与 /usr/local/etc 下）
rm -f /tmp/xray_config.json /tmp/hy2_config.yaml /tmp/wgcf-profile.conf /tmp/wgcf-account.toml

echo "==> 6/6 输出节点链接"
echo "--------------------------------------------------"
nodes
echo "--------------------------------------------------"
echo "完成。把上面两条链接导入 v2rayNG 即可使用（VLESS 与 HY2 任选其一或都导入）。"
echo "验证：手机连上后访问 ip.sb，应显示 VPS 所在地；YouTube 能打开即为全通。"
echo "注意：重装后 UUID/密码/IPv6 都变了，旧链接失效，必须导入这次输出的新链接。"
