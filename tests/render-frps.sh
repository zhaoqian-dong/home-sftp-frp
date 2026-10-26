#!/usr/bin/env bash
# CI 用：从 setup-vps.sh 提取 frps.toml 内嵌模板，按固定测试值渲染到 /tmp/ci-artifacts/
# 渲染逻辑与真实部署完全一致（heredoc + 变量展开），产物供 frps verify 与一致性校验使用
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR=/tmp/ci-artifacts
mkdir -p "$OUT_DIR"

awk '/^cat > "\$FRPS_CONF" <<EOF$/{flag=1;next}/^EOF$/{if(flag)exit}flag' \
    "$REPO_ROOT/scripts/setup-vps.sh" > "$OUT_DIR/frps-template.txt"

{
    echo 'FRP_BIND_PORT=7000'
    echo 'FRP_TOKEN=ci-test-token-0123456789abcdef'
    echo 'SFTP_PUBLIC_PORT=6022'
    echo 'DASH_USER=ciadmin'
    echo 'DASH_PASSWORD=ci-dash-pass-123'
    echo 'FRPS_LOG=/var/log/frps.log'
    echo "cat > \"$OUT_DIR/frps.toml\" <<EOF"
    cat "$OUT_DIR/frps-template.txt"
    echo 'EOF'
} > "$OUT_DIR/render.sh"

bash "$OUT_DIR/render.sh"
echo "rendered -> $OUT_DIR/frps.toml"
