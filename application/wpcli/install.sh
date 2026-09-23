#!/bin/bash
# WP-CLI 安装脚本（zap appstore 调用）
# 依赖环境变量（由 zapexec 注入）：ZAP_PATH APPS_DIR PKG_PATH APP_PATH APP_VERSION
#
# 说明：
#   * WP-CLI 是单文件 phar，安装到 ${APPS_DIR}/wpcli/wp-cli.phar，并注册全局命令
#     /usr/local/bin/wp（phar 自带 `#!/usr/bin/env php` shebang，可直接执行）。
#   * 依赖系统默认 PHP（php 命令），安装前需先安装 PHP。
#   * 下载的 phar 一律用官方 sha512 校验：摘要取不到或不一致就中止 —— 这是要注册成
#     全局命令的可执行文件，不能把完整性未确认的代码装进系统。
#   * 源地址可用环境变量 WP_CLI_PHAR_URL 覆盖（内网镜像 / 离线场景），同名 .sha512
#     必须一起提供。
set -euo pipefail

source "${ZAP_PATH}/scripts/zap/bash_utils.sh"

# ── PHP 依赖检查 ───────────────────────────────────────────
if ! command -v php >/dev/null 2>&1; then
    log_error "未找到 php 命令：请先在应用商店安装 PHP（安装时勾选「设为全局默认 PHP」）后再安装 WP-CLI"
    exit 1
fi
PHP_BIN="$(command -v php)"
log_info "使用 PHP: $("${PHP_BIN}" -v | head -n1)"
export HOME="/root"

# ── 安装位置 ───────────────────────────────────────────────
WP_DIR="${APPS_DIR}/wpcli"
WP_PHAR="${WP_DIR}/wp-cli.phar"
ensure_dir "${WP_DIR}"

# ── 下载 + 校验 ────────────────────────────────────────────
# 默认走配置的下载源（pkg_mirror）：远端镜像与本地目录都支持；
# 显式给 WP_CLI_PHAR_URL 时按老样子用官方源/自定义 URL。
if [ -n "${WP_CLI_PHAR_URL:-}" ]; then
    log_info "使用指定源下载 WP-CLI"
elif [ "${WP_CLI_PHAR_MIRROR}" = "zapsh" ]; then
    log_info "使用 Cloudflare 源下载 WP-CLI"
    WP_CLI_PHAR_URL="$(pkg_mirror | sed 's|mirrors\.zap\.cn|mirrors.zap.sh|')/wpcli/wp-cli.phar"
else
    log_info "使用配置的下载源下载 WP-CLI"
    WP_CLI_PHAR_URL="$(pkg_mirror)/wpcli/wp-cli.phar"
fi
PHAR_URL="${WP_CLI_PHAR_URL}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

log_info "下载 WP-CLI: ${PHAR_URL}"
# 走 fetch_file 而非裸 curl：本地目录源（离线环境）时它直接拷贝
download_file "${PHAR_URL}" "${TMP}/wp-cli.phar"
download_file "${PHAR_URL}.sha512" "${TMP}/wp-cli.phar.sha512"

EXPECT="$(awk '{print $1}' "${TMP}/wp-cli.phar.sha512" | tr 'A-Z' 'a-z')"
ACTUAL="$(sha512sum "${TMP}/wp-cli.phar" | awk '{print $1}' | tr 'A-Z' 'a-z')"
if [ -z "${EXPECT}" ]; then
    log_error "未取到官方校验和，已中止：不安装完整性无法确认的可执行文件"
    exit 1
fi
if [ "${EXPECT}" != "${ACTUAL}" ]; then
    log_error "校验和不匹配：期望 ${EXPECT:0:12}…，实际 ${ACTUAL:0:12}…"
    exit 1
fi
log_ok "sha512 校验通过"

install -m 0755 "${TMP}/wp-cli.phar" "${WP_PHAR}"
log_info "已安装: ${WP_PHAR}"

# ── 注册全局命令 ───────────────────────────────────────────
ln -sf "${WP_PHAR}" /usr/local/bin/wp
log_info "已注册全局命令 /usr/local/bin/wp"

# ── 验证可执行 ─────────────────────────────────────────────
VERSION_LINE="$(wp --version --no-ansi 2>&1 | head -n1)"
log_info "版本: ${VERSION_LINE}"

# ── 登记实例信息（apps/<category>/<name>/info.yaml）────────
ensure_dir "${APP_PATH}"
cat > "${APP_PATH}/info.yaml" <<EOF
install_dir: ${WP_DIR}
global_bin: /usr/local/bin/wp
phar: ${WP_PHAR}
version: ${VERSION_LINE}
EOF

log_info "WP-CLI 安装成功: ${VERSION_LINE}"
