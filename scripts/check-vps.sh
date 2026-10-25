#!/usr/bin/env bash
# ============================================================================
# check-vps.sh — VPS 端一键自检（对应 README 部署完成自检清单）
#
# 检查项：frps 安装与版本 / systemd 服务 / 配置文件 / 端口监听（TCP+UDP）/
#         管理面板仅回环 / ufw 与 fail2ban / frpc 隧道连通性（SSH banner 探测）
#
# 用法：把本脚本与 .env 一起上传 VPS（或 .env 缺省时按默认端口检查）
#       bash check-vps.sh
# 退出码：0 全部通过（可有 WARN）；1 存在 FAIL
# ============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
PASS=0; FAILN=0; WARNN=0
ok()   { echo -e "${GREEN}[PASS]${NC} $*"; PASS=$((PASS+1)); }
bad()  { echo -e "${RED}[FAIL]${NC} $*"; FAILN=$((FAILN+1)); }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; WARNN=$((WARNN+1)); }
step() { echo -e "${CYAN}==> $*${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 兼容两种部署布局：与 .env 同目录（scp 平铺）或仓库布局（.env 在 scripts/ 上级）
ENV_FILE=""
for cand in "${SCRIPT_DIR}/.env" "${SCRIPT_DIR}/../.env"; do
    if [ -f "$cand" ]; then ENV_FILE="$cand"; break; fi
done
env_get() {
    grep -E "^${1}=" "$ENV_FILE" 2>/dev/null | head -n1 | cut -d'=' -f2- \
        | tr -d '\r' | sed 's/^"//;s/"$//' || true
}
FRP_VERSION="${FRP_VERSION:-$(env_get FRP_VERSION)}";     FRP_VERSION="${FRP_VERSION:-0.71.1}"
FRP_BIND_PORT="$(env_get FRP_BIND_PORT)";                 FRP_BIND_PORT="${FRP_BIND_PORT:-7000}"
SFTP_PUBLIC_PORT="$(env_get SFTP_PUBLIC_PORT)";           SFTP_PUBLIC_PORT="${SFTP_PUBLIC_PORT:-6022}"

step "VPS 端自检（frp 控制通道 ${FRP_BIND_PORT} / SFTP 端口 ${SFTP_PUBLIC_PORT}）"

# ---------- 1. 二进制与版本 ----------
if [ -x /usr/local/bin/frps ]; then
    v="$(/usr/local/bin/frps --version 2>/dev/null || true)"
    if [ "$v" = "$FRP_VERSION" ]; then
        ok "frps v${v} 已安装，与 .env 的 FRP_VERSION 一致"
    else
        warn "frps 版本 ${v:-未知} 与 .env 期望的 ${FRP_VERSION} 不一致（改 .env 后重跑 setup-vps.sh 升级）"
    fi
else
    bad "未找到 /usr/local/bin/frps（重跑 setup-vps.sh）"
fi

# ---------- 2. systemd 服务 ----------
if [ "$(systemctl is-active frps 2>/dev/null || true)" = "active" ]; then
    ok "frps 服务运行中"
else
    bad "frps 未运行（查看：journalctl -u frps -n 50）"
fi
if [ "$(systemctl is-enabled frps 2>/dev/null || true)" = "enabled" ]; then
    ok "frps 已设开机自启"
else
    warn "frps 未设开机自启"
fi

# ---------- 3. 配置文件 ----------
if [ -f /etc/frp/frps.toml ]; then
    ok "配置文件 /etc/frp/frps.toml 存在"
    if sed -n 's/^auth\.token = "\(.*\)"$/\1/p' /etc/frp/frps.toml | grep -q .; then
        ok "auth.token 已配置"
    else
        bad "auth.token 为空（frpc 将无法认证）"
    fi
    if grep -q '^kcpBindPort' /etc/frp/frps.toml; then
        ok "kcpBindPort 已配置（UDP 通道就绪）"
    else
        warn "配置缺少 kcpBindPort（kcp 模式不可用，重跑 setup-vps.sh 更新）"
    fi
    if grep -q '^allowPorts' /etc/frp/frps.toml; then
        ok "已配置端口白名单（allowPorts，token 泄露也无法另开端口）"
    else
        warn "配置缺少 allowPorts 端口白名单 —— token 泄露时 VPS 可能被当跳板（重跑 setup-vps.sh）"
    fi
else
    bad "配置文件 /etc/frp/frps.toml 不存在"
fi

# ---------- 4. 端口监听 ----------
if ss -tln 2>/dev/null | grep -q ":${FRP_BIND_PORT} "; then
    ok "TCP ${FRP_BIND_PORT} 监听中（frp 控制通道）"
else
    bad "TCP ${FRP_BIND_PORT} 未监听（frps 异常或配置被改）"
fi
if ss -tln 2>/dev/null | grep -q ":${SFTP_PUBLIC_PORT} "; then
    ok "TCP ${SFTP_PUBLIC_PORT} 监听中（外网上传者入口）"
else
    bad "TCP ${SFTP_PUBLIC_PORT} 未监听"
fi
if ss -uln 2>/dev/null | grep -q ":${FRP_BIND_PORT} "; then
    ok "UDP ${FRP_BIND_PORT} 监听中（kcp 通道）"
else
    warn "UDP ${FRP_BIND_PORT} 未监听 —— kcp 模式将不可用（tcp 模式无影响）"
fi

# ---------- 5. 管理面板仅回环 ----------
if ! ss -tln 2>/dev/null | grep -q ':7500 '; then
    warn "7500 未监听（frps 管理面板未启用）"
elif ss -tln 2>/dev/null | awk '{print $4}' | grep -qE '(^|:)127\.0\.0\.1:7500$'; then
    ok "管理面板仅监听回环地址"
else
    bad "管理面板疑似对公网开放！检查 frps.toml 的 webServer.addr 应为 127.0.0.1"
fi

# ---------- 6. ufw ----------
if ufw status 2>/dev/null | grep -q "Status: active"; then
    ok "ufw 已启用"
else
    warn "ufw 未启用（VPS 端口全暴露，建议重跑 setup-vps.sh）"
fi
for spec in "${FRP_BIND_PORT}/tcp" "${FRP_BIND_PORT}/udp" "${SFTP_PUBLIC_PORT}/tcp"; do
    if ufw status 2>/dev/null | grep -q "${spec}"; then
        ok "ufw 已放行 ${spec}"
    else
        warn "ufw 缺少 ${spec} 放行（重跑 setup-vps.sh 补齐）"
    fi
done

# ---------- 7. fail2ban ----------
if [ "$(systemctl is-active fail2ban 2>/dev/null || true)" = "active" ]; then
    ok "fail2ban 运行中"
    if fail2ban-client status sshd >/dev/null 2>&1; then
        ok "fail2ban sshd jail 已启用"
    else
        warn "fail2ban 缺少 sshd jail"
    fi
else
    warn "fail2ban 未运行（SSH 爆破无防护，建议重跑 setup-vps.sh）"
fi

# ---------- 8. 自动安全更新 ----------
if [ "$(systemctl is-enabled unattended-upgrades 2>/dev/null || true)" = "enabled" ]; then
    ok "unattended-upgrades 自动安全更新已启用"
else
    warn "自动安全更新未启用（长期运行的 VPS 建议开启，重跑 setup-vps.sh）"
fi

# ---------- 9. 隧道连通性（免凭据） ----------
banner="$(timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/${SFTP_PUBLIC_PORT} && head -c 4 <&3" 2>/dev/null || true)"
if [ "${banner:-}" = "SSH-" ]; then
    ok "隧道连通：127.0.0.1:${SFTP_PUBLIC_PORT} 返回 SSH banner（家里 frpc 已挂载）"
else
    warn "127.0.0.1:${SFTP_PUBLIC_PORT} 无 SSH banner —— 家里 frpc 尚未连接（属正常，若家庭端已部署则检查其 frpc 日志）"
fi

# ---------- 摘要 ----------
echo
echo -e "${CYAN}自检完成：${GREEN}${PASS} 通过${NC} / ${YELLOW}${WARNN} 警告${NC} / ${RED}${FAILN} 失败${NC}"
if [ "$FAILN" -gt 0 ]; then
    echo -e "${YELLOW}提示：以上 FAIL 项修复后重跑本脚本；全部通过但上传者仍连不上时，${NC}"
    echo -e "${YELLOW}九成是腾讯云控制台防火墙没放行对应端口（脚本无法代办）。${NC}"
    exit 1
fi
exit 0
