#!/usr/bin/env bash
# ============================================================================
# setup-vps.sh — 公网 VPS（Ubuntu）一键安装 frps 反向代理服务端
#
# 功能：
#   1. 安装 frps（frp server）并注册 systemd 服务（开机自启、崩溃重启）
#   2. 生成 /etc/frp/frps.toml（token 认证 + 强制 TLS + 管理面板仅回环）
#   3. 配置 fail2ban 防 SSH 爆破、ufw 防火墙放行必要端口
#
# 用法：
#   1. 把本脚本与 .env 上传到 VPS 同一目录：
#        scp setup-vps.sh .env root@<VPS_IP>:/root/
#   2. 登录 VPS 执行：
#        sudo bash setup-vps.sh
#   3. 按脚本结尾提示，把生成的 FRP_TOKEN 回填到本地 .env
#
# 参考：https://github.com/fatedier/frp
# ============================================================================
set -euo pipefail

FRP_VERSION="0.71.1"          # frp 版本，升级时只改这里
FRP_BIN="/usr/local/bin/frps"
FRP_ETC="/etc/frp"
FRPS_CONF="${FRP_ETC}/frps.toml"
FRPS_LOG="/var/log/frps.log"

# ---------- 输出工具 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
step()  { echo -e "${CYAN}==> $*${NC}"; }
fail()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ---------- 前置检查 ----------
[[ $EUID -eq 0 ]] || fail "请用 root 运行：sudo bash $0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
[[ -f "$ENV_FILE" ]] || fail "未找到 .env（请与脚本放在同一目录）"

# 从 .env 读取指定 key（不 source，避免 Windows 路径反斜杠等问题）；
# 末尾 || true 保证 key 不存在时（grep 非零）不会触发 set -e 中断脚本
env_get() {
    grep -E "^${1}=" "$ENV_FILE" 2>/dev/null | head -n1 | cut -d'=' -f2- \
        | tr -d '\r' | sed 's/^"//;s/"$//' || true
}

FRP_BIND_PORT="$(env_get FRP_BIND_PORT)";       FRP_BIND_PORT="${FRP_BIND_PORT:-7000}"
SFTP_PUBLIC_PORT="$(env_get SFTP_PUBLIC_PORT)"; SFTP_PUBLIC_PORT="${SFTP_PUBLIC_PORT:-6022}"
FRP_TRANSPORT="$(env_get FRP_TRANSPORT)";       FRP_TRANSPORT="${FRP_TRANSPORT:-tcp}"
VPS_IP="$(env_get VPS_IP)"
FRP_TOKEN="$(env_get FRP_TOKEN)"

case "$FRP_TRANSPORT" in
    tcp|kcp) ;;
    *) fail "FRP_TRANSPORT 仅支持 tcp 或 kcp（当前：$FRP_TRANSPORT）" ;;
esac

# ---------- 1. 系统依赖 ----------
step "1/5 安装系统依赖（curl unzip fail2ban ufw openssl）"
PKGS=()
command -v curl           >/dev/null 2>&1 || PKGS+=(curl)
command -v unzip          >/dev/null 2>&1 || PKGS+=(unzip)
command -v fail2ban-client >/dev/null 2>&1 || PKGS+=(fail2ban)
command -v ufw            >/dev/null 2>&1 || PKGS+=(ufw)
command -v openssl        >/dev/null 2>&1 || PKGS+=(openssl)
if [ "${#PKGS[@]}" -gt 0 ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y "${PKGS[@]}"
else
    info "依赖已齐全，跳过"
fi

# ---------- 2. token ----------
step "2/5 准备 frp 通信令牌"
if [ -f "$FRPS_CONF" ] && [ -z "$FRP_TOKEN" ]; then
    # 幂等：重跑且 .env 未回填时，沿用已生成的 token，避免家里 frpc 对不上
    FRP_TOKEN="$(sed -n 's/^auth\.token = "\(.*\)"$/\1/p' "$FRPS_CONF" | head -n1)"
    [ -n "$FRP_TOKEN" ] && warn "检测到已有部署且 .env 未填 FRP_TOKEN，沿用旧 token"
fi
if [ -z "$FRP_TOKEN" ]; then
    FRP_TOKEN="$(openssl rand -hex 16)"
    TOKEN_GENERATED=1
    info "已自动生成 FRP_TOKEN"
else
    info "使用 .env 中提供的 FRP_TOKEN"
fi

DASH_USER="admin"
DASH_PASSWORD="$(openssl rand -hex 8)"

# ---------- 3. 下载安装 frps ----------
step "3/5 下载并安装 frp v${FRP_VERSION}"
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)          FRP_ARCH="amd64" ;;
    aarch64|arm64)   FRP_ARCH="arm64" ;;
    *) fail "不支持的 CPU 架构：$ARCH" ;;
esac

NEED_INSTALL=1
if [ -x "$FRP_BIN" ]; then
    CURRENT_VER="$("$FRP_BIN" --version 2>/dev/null || true)"
    if [ "$CURRENT_VER" = "$FRP_VERSION" ]; then
        info "frps v${FRP_VERSION} 已安装，跳过下载"
        NEED_INSTALL=0
    fi
fi

if [ "$NEED_INSTALL" -eq 1 ]; then
    FRP_PKG="frp_${FRP_VERSION}_linux_${FRP_ARCH}.tar.gz"
    RELEASE_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}"
    # 国内 VPS 访问 GitHub 慢/失败时自动回退加速镜像
    URLS=(
        "${RELEASE_URL}/${FRP_PKG}"
        "https://gh-proxy.com/${RELEASE_URL}/${FRP_PKG}"
        "https://ghfast.top/${RELEASE_URL}/${FRP_PKG}"
    )
    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "$TMP_DIR"' EXIT
    DOWNLOADED=0
    for u in "${URLS[@]}"; do
        info "尝试下载：$u"
        if curl -fSL --connect-timeout 8 --max-time 300 -o "${TMP_DIR}/${FRP_PKG}" "$u"; then
            DOWNLOADED=1; break
        fi
        warn "下载失败，尝试下一个源..."
    done
    [ "$DOWNLOADED" -eq 1 ] || fail "所有下载源均失败，请检查 VPS 网络后重试"
    tar -xzf "${TMP_DIR}/${FRP_PKG}" -C "$TMP_DIR"
    install -m 755 "${TMP_DIR}/frp_${FRP_VERSION}_linux_${FRP_ARCH}/frps" "$FRP_BIN"
    info "frps 已安装到 $FRP_BIN"
fi

# ---------- 4. 生成配置与 systemd 服务 ----------
step "4/5 生成 frps.toml 与 systemd 服务"
mkdir -p "$FRP_ETC"
if [ -f "$FRPS_CONF" ]; then
    cp "$FRPS_CONF" "${FRPS_CONF}.bak.$(date +%Y%m%d%H%M%S)"
    info "已备份旧配置"
fi

cat > "$FRPS_CONF" <<EOF
# 由 setup-vps.sh 于 $(date '+%Y-%m-%d %H:%M:%S') 自动生成
bindAddr = "0.0.0.0"
bindPort = ${FRP_BIND_PORT}

# KCP（UDP）控制通道端口，与 TCP 同端口号互不冲突。
# 仅当家里 frpc 配置 transport.protocol = "kcp" 时才会用到
kcpBindPort = ${FRP_BIND_PORT}

auth.method = "token"
auth.token = "${FRP_TOKEN}"

# 强制所有 frpc 使用 TLS 连接
transport.tls.force = true

# 管理面板仅监听本机回环（通过 SSH 隧道访问，见脚本结尾说明）
webServer.addr = "127.0.0.1"
webServer.port = 7500
webServer.user = "${DASH_USER}"
webServer.password = "${DASH_PASSWORD}"

log.to = "${FRPS_LOG}"
log.level = "info"
log.maxDays = 7
EOF
chmod 600 "$FRPS_CONF"

cat > /etc/systemd/system/frps.service <<EOF
[Unit]
Description=frp Server (frps) - reverse proxy for home SFTP
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${FRP_BIN} -c ${FRPS_CONF}
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now frps
systemctl restart frps
sleep 1
systemctl is-active --quiet frps || fail "frps 启动失败，请查看：journalctl -u frps -n 50"
info "frps 服务已启动"

# ---------- 5. fail2ban 与防火墙 ----------
step "5/5 配置 fail2ban 与 ufw 防火墙"

cat > /etc/fail2ban/jail.d/sshd.local <<'EOF'
# 防止 SSH 爆破（Ubuntu 24.04 日志走 journald，需 backend=systemd）
[sshd]
enabled  = true
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban
info "fail2ban 已启用（SSH 5 次失败封禁 1 小时）"

ufw allow 22/tcp comment 'SSH'                       >/dev/null
ufw allow "${FRP_BIND_PORT}/tcp" comment 'frp control' >/dev/null
# UDP 同端口号供 KCP 模式使用；纯 tcp 模式下放行也无害
ufw allow "${FRP_BIND_PORT}/udp" comment 'frp control (kcp)' >/dev/null
ufw allow "${SFTP_PUBLIC_PORT}/tcp" comment 'SFTP via frp' >/dev/null
ufw --force enable
info "ufw 已启用：放行 22 / ${FRP_BIND_PORT}(TCP+UDP) / ${SFTP_PUBLIC_PORT}（管理面板 7500 刻意不对公网开放）"

# ---------- 结果摘要 ----------
if [ "$FRP_TRANSPORT" = "kcp" ]; then
    TRANSPORT_LINE="kcp（UDP 传输，家宽/跨境丢包线路吞吐更好）"
    FIREWALL_LINES="      22                （你自己管理 VPS，TCP）
      ${FRP_BIND_PORT}            （frp 隧道，TCP 与 UDP 都要放行）
      ${SFTP_PUBLIC_PORT}            （外网上传者连接 SFTP，TCP）"
else
    TRANSPORT_LINE="tcp（默认）"
    FIREWALL_LINES="      22                （你自己管理 VPS，TCP）
      ${FRP_BIND_PORT}            （frp 隧道，TCP）
      ${SFTP_PUBLIC_PORT}            （外网上传者连接 SFTP，TCP）"
fi
echo
echo -e "${CYAN}============================================================${NC}"
echo -e "${GREEN}  VPS 端 frps 部署完成${NC}"
echo -e "${CYAN}============================================================${NC}"
if [ "${TOKEN_GENERATED:-0}" -eq 1 ]; then
    echo -e "${YELLOW}【必做】把下面这行回填到你本地 .env 后，同步给家里 Windows：${NC}"
    echo
    echo "    FRP_TOKEN=${FRP_TOKEN}"
    echo
fi
cat <<INFO

  frps 控制通道端口 : ${FRP_BIND_PORT}（frpc 用；传输协议：${TRANSPORT_LINE}）
  公网 SFTP 端口    : ${SFTP_PUBLIC_PORT}（外网上传者连接）
  管理面板          : http://127.0.0.1:7500 （用户 ${DASH_USER} / 密码 ${DASH_PASSWORD}）
                      在本机执行: ssh -L 7500:127.0.0.1:7500 root@${VPS_IP:-<VPS_IP>}
  frps 日志         : ${FRPS_LOG}

  ${YELLOW}【必做】腾讯云控制台防火墙${NC}（脚本无法代办）：
    轻量应用服务器控制台 -> 防火墙 -> 添加规则，放行：
${FIREWALL_LINES}

  下一步：
    1. 回填 FRP_TOKEN 到 .env（若上面有提示）
    2. 把整个 windows/ 目录 + .env 复制到家里 Windows 机器
    3. 按 README 在家里 Windows 执行 setup-home-windows.ps1

INFO
