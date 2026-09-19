#!/bin/bash
# OpenSSL 库卸载脚本(zap appstore 调用)
# 依赖环境变量(由 zapexec 注入):ZAP_PATH APPS_DIR APP_OLD_VERSION
set -euo pipefail

source "${ZAP_PATH}/scripts/zap/bash_utils.sh"



#从APP_OLD_VERSION 解析旧版本，获取 MAJOR_VERSION MINOR_VERSION
OLD_MAJOR_VERSION=$(version_major "${APP_OLD_VERSION}")
OLD_MINOR_VERSION=$(version_minor "${APP_OLD_VERSION}")
SHORT_VERSION="${OLD_MAJOR_VERSION}.${OLD_MINOR_VERSION}"
INSTALL_DIR="${APPS_DIR}/openssl${SHORT_VERSION}"

INFO_FILE="${APP_PATH}/info.yaml"
INSTALL_DIR="$(resolve_install_dir "${INFO_FILE}" "${LINK_DIR}")"


echo "uninstall openssl ${SHORT_VERSION}  ${INSTALL_DIR}"

# ── ld.so 索引片段(按 major 分文件,不影响其它 major 实例) ────────────────
rm -f "/etc/ld.so.conf.d/zap-openssl-${OLD_MAJOR_VERSION}.conf"
ldconfig >/dev/null 2>&1 || true

# 删除前的安全校验：必须位于 APPS_DIR 之下且是其直接子目录
assert_under_apps_dir "${INSTALL_DIR}" "${APPS_DIR}" || exit 1
if [ "$(dirname "${INSTALL_DIR}")" != "${APPS_DIR}" ]; then
    log_error "安装目录不在 ${APPS_DIR} 下，无法卸载"
    exit 1
fi

# ── 依赖检查:列出运行期仍链接本实例的应用程序 ──────────────
# 链接方(如 PHP 7.x-8.0)已把本实例 lib 写进自己的 RUNPATH,不经过 ld.so.cache,
# 故删除上面的 conf 片段不会立刻影响它们;真正会让它们失效的是下面删除安装目录。
# 这里只告警、不阻断卸载。
if command -v readelf >/dev/null 2>&1; then
    case "${OLD_MAJOR_VERSION}" in
        3) _so="libssl\.so\.3" ;;
        *) _so="libssl\.so\.${OLD_MAJOR_VERSION}\.[0-9]" ;;
    esac
    _dependents=""
    for _b in "${APPS_DIR}"/*/bin/* "${APPS_DIR}"/*/sbin/*; do
        [ -f "${_b}" ] || continue
        if readelf -d "${_b}" 2>/dev/null | grep -qE "${_so}"; then
            _dependents="${_dependents} ${_b}"
        fi
    done
    if [ -n "${_dependents}" ]; then
        log_warn "以下程序仍链接 openssl${SHORT_VERSION},删除后它们将无法启动:${_dependents}"
    fi
fi

if [ -d "${INSTALL_DIR}" ]; then
    rm -rf "${INSTALL_DIR}"
fi

echo "openssl uninstall successful"
