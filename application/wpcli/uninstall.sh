#!/bin/bash
# WP-CLI 卸载脚本（zap appstore 调用）
# 依赖环境变量（由 zapexec 注入）：ZAP_PATH APPS_DIR PKG_PATH APP_PATH
set -euo pipefail

source "${ZAP_PATH}/scripts/zap/bash_utils.sh"

WP_DIR="${APPS_DIR}/wpcli"
WP_PHAR="${WP_DIR}/wp-cli.phar"

# ── 移除全局命令链接（仅当指向本实例）──────────────────────
if [ -L /usr/local/bin/wp ] && [ "$(readlink /usr/local/bin/wp)" = "${WP_PHAR}" ]; then
    rm -f /usr/local/bin/wp
    log_info "已移除全局命令 /usr/local/bin/wp"
fi

# ── 清理 wp-cli 自身的缓存 / 包目录（root 下运行产生）──────
rm -rf "${HOME:-/root}/.wp-cli"

# ── 删除安装目录 ───────────────────────────────────────────
rm -rf "${WP_DIR}"

log_info "WP-CLI 已卸载"
