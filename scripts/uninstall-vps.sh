#!/usr/bin/env bash
# ============================================================================
# uninstall-vps.sh — 移除 VPS 端 frps 及本项目添加的防火墙/防爆破配置
#
# 移除：frps 服务与二进制、/etc/frp、日志、本项目 fail2ban jail、
#       ufw 中 frp 相关端口规则（TCP/UDP）
# 保留：ufw 本体与 22 端口规则、fail2ban 本体（仍保护你的 SSH）
#
# 用法：
#   sudo bash uninstall-vps.sh          # 交互确认后执行
#   sudo bash uninstall-vps.sh --yes    # 跳过确认
# 重新安装：重跑 setup-vps.sh 即可
# ============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "请用 root 运行：sudo bash $0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 兼容两种部署布局：与 .env 同目录（scp 平铺）或仓库布局（.env 在 scripts/ 上级）
ENV_FILE=""
for cand in "${SCRIPT_DIR}/.env" "${SCRIPT_DIR}/../.env"; do
    if [ -f "$cand" ]; then ENV_FILE="$cand"; break; fi
done

# 端口读取（.env 不在时用默认值，规则删除仍按尝试执行）
env_get() {
    grep -E "^${1}=" "$ENV_FILE" 2>/dev/null | head -n1 | cut -d'=' -f2- \
        | tr -d '\r' | sed 's/^"//;s/"$//' || true
}
FRP_BIND_PORT="$(env_get FRP_BIND_PORT)";       FRP_BIND_PORT="${FRP_BIND_PORT:-7000}"
SFTP_PUBLIC_PORT="$(env_get SFTP_PUBLIC_PORT)"; SFTP_PUBLIC_PORT="${SFTP_PUBLIC_PORT:-6022}"

if [ "${1:-}" != "--yes" ]; then
    read -r -p "确认移除 VPS 端 frps 及本项目防火墙规则？（输入 yes 继续）：a" a
    [ "$a" = "yes" ] || { echo "已取消"; exit 0; }
fi

# ---------- 1. frps 服务与文件 ----------
step() { echo -e "${CYAN}==> $*${NC}"; }
step "1/3 移除 frps 服务、二进制与配置"
systemctl disable --now frps 2>/dev/null || true
rm -f /etc/systemd/system/frps.service
systemctl daemon-reload
rm -f /usr/local/bin/frps
rm -rf /etc/frp
rm -f /var/log/frps.log
info "frps 已移除（含配置备份与日志）"

# ---------- 2. fail2ban jail ----------
step "2/3 移除本项目 fail2ban jail"
rm -f /etc/fail2ban/jail.d/sshd.local
if systemctl is-active --quiet fail2ban 2>/dev/null; then
    systemctl restart fail2ban
fi
info "已移除本项目 jail（fail2ban 本体保留，仍保护你的 SSH）"

# ---------- 3. ufw 规则 ----------
step "3/3 移除 ufw 中 frp 相关规则"
# 兼容历史部署：放行规则可能是 allow（旧版脚本）或 limit（新版脚本）
ufw delete allow "${FRP_BIND_PORT}/tcp"    >/dev/null 2>&1 || true
ufw delete allow "${FRP_BIND_PORT}/udp"    >/dev/null 2>&1 || true
ufw delete allow "${SFTP_PUBLIC_PORT}/tcp" >/dev/null 2>&1 || true
ufw delete limit "${SFTP_PUBLIC_PORT}/tcp" >/dev/null 2>&1 || true
info "已移除 ${FRP_BIND_PORT}(TCP+UDP) / ${SFTP_PUBLIC_PORT} 的放行规则（保留 22 与 ufw 本体）"

# ---------- 摘要 ----------
echo
echo -e "${CYAN}============================================================${NC}"
echo -e "${GREEN}  VPS 端已卸载完成${NC}"
echo -e "${CYAN}============================================================${NC}"
cat <<INFO

  已移除：frps 服务/二进制/配置/日志、本项目 fail2ban jail、frp 端口放行规则
  保留  ：ufw（仅 22 为 limit 限速）、fail2ban（sshd 防爆破）、
          unattended-upgrades 自动安全更新

  如需彻底清理残留组件（一般不建议，它们仍在保护你的 SSH）：
    apt-get remove --purge -y fail2ban     # 移除 fail2ban
    ufw disable                             # 关闭防火墙

  重新安装：重跑 setup-vps.sh 即可
INFO
