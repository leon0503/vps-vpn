#!/bin/bash
# 卸载 vps-vpn（停止并删除服务与配置，客户端链接随即失效，确认后再运行）
# 用法：sudo ./uninstall.sh
# 注意：这会删除 Xray/HY2/wgcf 的配置与证书；程序本体（xray、hysteria、wgcf 二进制）未删除，
# 如需彻底删除请手动处理，或直接重装系统。
set -e
if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root 运行" >&2
  exit 1
fi
read -p "确认卸载 Xray + HY2 + wgcf？输入 YES 继续：" ans
[ "$ans" != "YES" ] && { echo "已取消"; exit 0; }
systemctl stop xray hysteria-server wg-quick@wgcf 2>/dev/null || true
systemctl disable xray hysteria-server wg-quick@wgcf 2>/dev/null || true
rm -rf /usr/local/etc/xray /etc/hysteria /etc/wireguard/wgcf.conf /etc/wireguard/wgcf-account.toml /usr/local/bin/nodes /etc/node-name
echo "已卸载。"
