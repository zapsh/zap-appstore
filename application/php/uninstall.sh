#!/bin/bash
# PHP 卸载脚本（zap appstore 调用）
# 依赖环境变量（由 zapexec 注入）：APPS_DIR APP_VERSION MAJOR_VERSION MINOR_VERSION
set -euo pipefail

# 版本短名 = 主版本+次版本直接拼接(不带点):8.5.33 → 85,与安装脚本一致。
PHP_SHORT_VERSION="${MAJOR_VERSION}${MINOR_VERSION}"
PHP_INSTALL_PATH="${APPS_DIR}/php-${PHP_SHORT_VERSION}"
SERVICE_NAME="php-fpm-${PHP_SHORT_VERSION}"

echo "uninstall PHP ${APP_VERSION}"

# ── 停止并移除服务 ─────────────────────────────────────────
if command -v systemctl >/dev/null 2>&1; then
    systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
    systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload 2>/dev/null || true
fi
if command -v chkconfig >/dev/null 2>&1; then
    chkconfig --del "${SERVICE_NAME}" 2>/dev/null || true
    rm -f "/etc/init.d/${SERVICE_NAME}"
fi

# ── 移除全局命令链接 ───────────────────────────────────────
# 判断当前全局的命令是链接的当前版本
if [ -L /usr/local/bin/php ] && [ "$(readlink /usr/local/bin/php)" = "${PHP_INSTALL_PATH}/bin/php" ]; then
    echo "Removing global php link..."
    rm -f /usr/local/bin/php
fi
if [ -L /usr/local/bin/php-cgi ] && [ "$(readlink /usr/local/bin/php-cgi)" = "${PHP_INSTALL_PATH}/bin/php-cgi" ]; then
    echo "Removing global php-cgi link..."
    rm -f /usr/local/bin/php-cgi
fi
if [ -L /usr/local/bin/pear ] && [ "$(readlink /usr/local/bin/pear)" = "${PHP_INSTALL_PATH}/bin/pear" ]; then
    echo "Removing global pear link..."
    rm -f /usr/local/bin/pear
fi
if [ -L /usr/local/bin/pecl ] && [ "$(readlink /usr/local/bin/pecl)" = "${PHP_INSTALL_PATH}/bin/pecl" ]; then
    echo "Removing global pecl link..."
    rm -f /usr/local/bin/pecl
fi
# 补链 /usr/bin/php 同样仅当指向本实例才移除，避免卸载默认版本后残留失效链接
if [ -L /usr/bin/php ] && [ "$(readlink /usr/bin/php)" = "${PHP_INSTALL_PATH}/bin/php" ]; then
    echo "Removing global /usr/bin/php link..."
    rm -f /usr/bin/php
fi


# ── 删除安装目录（zap 侧随后清理 APP_PATH 元数据目录） ─────
if [ -d "${PHP_INSTALL_PATH}" ]; then
    echo "Removing ${PHP_INSTALL_PATH}..."
    rm -rf "${PHP_INSTALL_PATH}"
    echo "Removing done."
fi

# ── openssl 依赖提示 ───────────────────────────────────────
# PHP 7.x-8.0 链接 openssl1.1 实例(安装时已写进 RUNPATH),卸载本实例后若已无其它
# PHP 实例引用,openssl1.1 即为孤儿库。只提示、不自动删,交由用户决定。
if [[ "${APP_VERSION}" < "8.1.0" ]] && [ -d "${APPS_DIR}/openssl1.1" ] && command -v readelf >/dev/null 2>&1; then
    _still_used=0
    for _d in "${APPS_DIR}"/php-*; do
        [ -d "${_d}" ] || continue
        [ "${_d}" = "${PHP_INSTALL_PATH}" ] && continue
        for _b in "${_d}/bin/php" "${_d}/sbin/php-fpm"; do
            if [ -f "${_b}" ] && readelf -d "${_b}" 2>/dev/null | grep -qE "openssl1\.1|libssl\.so\.1\.1"; then
                _still_used=1
                break 2
            fi
        done
    done
    if [ "${_still_used}" -eq 0 ]; then
        echo "提示:已无其它 PHP 实例引用 openssl1.1,可在面板卸载「openssl 1.1」"
    fi
fi

echo "php uninstall successful"
