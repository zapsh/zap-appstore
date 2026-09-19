#!/bin/bash
# PHP 编译安装脚本（zap appstore 调用）
# 依赖环境变量（由 zapexec 注入）：ZAP_PATH APPS_DIR PKG_PATH APP_PATH APP_VERSION MAJOR_VERSION MINOR_VERSION BUILD_PATH CPU_NUM ZAP_DATA_PATH
# 可选（options.build，值原样注入）：
#   EXTS        多选，空格拼接 —— 如 "bcmath calendar exif"
#   SET_DEFAULT bool —— "true"（默认）注册为系统全局默认；"false" 不触碰 /usr/local/bin
#
# 版本兼容性提示：
#   PHP 7.0 要求 OpenSSL >= 0.9.8, < 1.2
#   PHP 7.1-8.0 要求 OpenSSL >= 1.0.1, < 3.0
#   PHP >= 8.1 要求 OpenSSL >= 1.0.2, < 4.0
set -euo pipefail

source "${ZAP_PATH}/scripts/zap/bash_utils.sh"

# ── 编译依赖 ───────────────────────────────────────────────
# 逐个安装：apt 只要有一个包名找不到就整条命令失败、一个都不装，
# 所以不能写成 `apt-get install -y <一长串> || true`（那样等于静默全不装）。
# 单个依赖缺失在 configure / make 阶段会暴露，故只告警、不中断。
PKG_MGR="$(pkg_manager || true)"
case "${PKG_MGR}" in
    apt)
        apt-get update -y >/dev/null 2>&1 || log_warn "apt-get update 失败(继续尝试安装)"
        for p in libxml2-dev libsqlite3-dev libcurl4-openssl-dev libjpeg-dev libwebp-dev \
                 libpng-dev libonig-dev libicu-dev libzip-dev libpq-dev zlib1g-dev pkg-config; do
            pkg_install_any apt "$p" || true
        done
        ;;
    dnf | yum)
        for p in libxml2-devel sqlite-devel curl-devel libjpeg-devel libwebp-devel \
                 libpng-devel oniguruma-devel libicu-devel libzip-devel postgresql-devel \
                 zlib-devel pkgconfig; do
            pkg_install_any "${PKG_MGR}" "$p" || true
        done
        ;;
    *)
        log_warn "未识别的包管理器：请自行确认编译依赖已安装"
        ;;
esac

# ── 前置：运行用户 www（php-fpm 以 www 运行）+ 目录 + 首次系统编译依赖 ──────
prepare_install_env www

# ── 低版本 PHP 需要 openssl 1.1 ───────────────────────────
# PHP 7.x-8.0 仅兼容 OpenSSL < 3.0,必须链 1.1 实例:
#   * export PKG_CONFIG_PATH 指向 1.1 实例(其 openssl.pc 的 prefix/libdir 均
#     指向实例自身,供 ext 的 pkg-config 检查与 >= 8.1 走 pkg-config 时使用);
#   * PHP 7.x configure 额外支持 --with-openssl=<DIR> 前缀形式:头文件与链接
#     库直接取自该实例,完全不受系统 pkg-config 默认(3.x)影响,最稳。
OPENSSL_OPTS="--with-openssl"
if [[ "${APP_VERSION}" < "8.1.0" ]]; then
    if [ ! -d "${APPS_DIR}/openssl1.1" ]; then
        log_error "Please install openssl1.1 first"
        exit 1
    fi
    export PKG_CONFIG_PATH="${APPS_DIR}/openssl1.1/lib/pkgconfig"
    OPENSSL_OPTS="--with-openssl=${APPS_DIR}/openssl1.1"
fi
log_info "PKG_CONFIG_PATH: ${PKG_CONFIG_PATH:-} | OPENSSL_OPTS: ${OPENSSL_OPTS}"

PHP_VERSION="${APP_VERSION}"
# 版本短名 = 主版本号+次版本号直接拼接(不带点):8.5.33 → 85。
# 由此派生出 目录 php-85 / 服务 php-fpm-85 / sock、pid php-fpm-85.sock、.pid,
# 与 zapd/zapexec 的命名约定一致(php85 → /var/run/php-fpm-85.sock)。
PHP_SHORT_VERSION="${MAJOR_VERSION}${MINOR_VERSION}"
PHP_DOWNLOAD_URL="https://mirrors.zap.cn/pkg/php/php-${PHP_VERSION}.tar.gz"
PHP_DOWNLOAD_NAME="php-${PHP_VERSION}.tar.gz"
PHP_INSTALL_PATH="${APPS_DIR}/php-${PHP_SHORT_VERSION}"
PHP_FPM_SOCK="/var/run/php-fpm-${PHP_SHORT_VERSION}.sock"
PHP_FPM_PID="/var/run/php-fpm-${PHP_SHORT_VERSION}.pid"
PHP_ERROR_LOG="/var/log/php/php-${PHP_SHORT_VERSION}.log"
PHP_FPM_ERROR_LOG="/var/log/php/php-fpm-${PHP_SHORT_VERSION}.log"

cd "${PKG_PATH}"
if [ ! -f "${PHP_DOWNLOAD_NAME}" ]; then
    log_info "Downloading PHP"
    download_file "${PHP_DOWNLOAD_URL}" "${PHP_DOWNLOAD_NAME}"
fi

log_info "unpacking PKGs"
rm -rf "${BUILD_PATH}"
mkdir -p "${BUILD_PATH}"
tar -xzf "${PHP_DOWNLOAD_NAME}" -C "${BUILD_PATH}"

# ── 编译安装 ───────────────────────────────────────────────
log_info "building PHP ${APP_VERSION}"
cd "${BUILD_PATH}/php-${APP_VERSION}"

# GD 相关选项随版本差异：PHP 7.x 用 --with-jpeg-dir，8.0 起用 --with-jpeg，8.1 起支持 --with-webp
GD_OPT="--enable-gd"
if [[ "${MAJOR_VERSION}" == "7" ]]; then
    GD_OPT="${GD_OPT} --with-jpeg-dir"
else
    GD_OPT="${GD_OPT} --with-jpeg"
    if [[ "${APP_VERSION}" > "8.1.0" ]]; then
        GD_OPT="${GD_OPT} --with-webp"
    fi
fi

# ── 用户可选扩展（options.build 的 EXTS 多选，勾选值按空格拼接注入 $EXTS）──
# 逐个展开为 --enable-<ext> 追加到 configure；choices value 即开关名，白名单外跳过
EXT_OPTS=()
if [ -n "${EXTS:-}" ]; then
    read -r -a _exts <<< "${EXTS}"
    for _e in "${_exts[@]}"; do
        case "${_e}" in
            bcmath|calendar|exif|fileinfo)
                EXT_OPTS+=(--enable-${_e}) ;;
            *)
                log_warn "未识别的扩展「${_e}」，已跳过" ;;
        esac
    done
    if [ ${#EXT_OPTS[@]} -gt 0 ]; then
        log_info "本次安装启用扩展: ${EXTS}"
    fi
fi

./configure \
    --prefix="${PHP_INSTALL_PATH}" \
    --with-config-file-path="${PHP_INSTALL_PATH}/etc" \
    --with-config-file-scan-dir="${PHP_INSTALL_PATH}/etc/php.d" \
    --disable-rpath \
    --enable-sysvsem \
    --enable-sysvshm \
    --enable-pcntl \
    --enable-fpm \
    --with-fpm-user=www \
    --with-fpm-group=www \
    ${OPENSSL_OPTS} \
    --with-zlib \
    --with-zip \
    --enable-soap \
    --enable-sockets \
    --with-curl \
    ${GD_OPT} \
    --enable-mysqlnd \
    --with-mysqli=mysqlnd \
    --with-pdo-mysql=mysqlnd \
    --enable-mbstring \
    --enable-intl \
    --with-pear \
    "${EXT_OPTS[@]}"

log_info "make install"
make -j "${CPU_NUM:-1}" && make install

if [ ! -d "${PHP_INSTALL_PATH}" ]; then
    log_error "PHP ${APP_VERSION} Install failed"
    exit 1
fi

# ── 配置文件 ───────────────────────────────────────────────
mkdir -p "${PHP_INSTALL_PATH}/etc/php.d"
# php.ini：优先官方模板，缺失时回退，保证面板"服务配置 → PHP"始终有可编辑的主配置
# （PHP 没有 php.ini 也能跑，会退回内置默认值，导致面板探测不到配置）
if [ -f "${BUILD_PATH}/php-${APP_VERSION}/php.ini-production" ]; then
    cp "${BUILD_PATH}/php-${APP_VERSION}/php.ini-production" "${PHP_INSTALL_PATH}/etc/php.ini"
elif [ -f "${BUILD_PATH}/php-${APP_VERSION}/php.ini-development" ]; then
    cp "${BUILD_PATH}/php-${APP_VERSION}/php.ini-development" "${PHP_INSTALL_PATH}/etc/php.ini"
elif [ -f "${PHP_INSTALL_PATH}/etc/php.ini-production" ]; then
    cp "${PHP_INSTALL_PATH}/etc/php.ini-production" "${PHP_INSTALL_PATH}/etc/php.ini"
else
    log_warn "源码包未提供 php.ini 模板，写入最小化 php.ini"
    cat > "${PHP_INSTALL_PATH}/etc/php.ini" <<'PHPEOF'
[PHP]
memory_limit = 128M
post_max_size = 32M
upload_max_filesize = 32M
max_execution_time = 60
max_input_time = 60
date.timezone = Asia/Shanghai
display_errors = Off
expose_php = Off
PHPEOF
fi
if [ -f "${BUILD_PATH}/php-${APP_VERSION}/sapi/fpm/php-fpm.conf" ]; then
    cp "${BUILD_PATH}/php-${APP_VERSION}/sapi/fpm/php-fpm.conf" "${PHP_INSTALL_PATH}/etc/php-fpm.conf"
else
    cp "${PHP_INSTALL_PATH}/etc/php-fpm.conf.default" "${PHP_INSTALL_PATH}/etc/php-fpm.conf"
fi
if [ -f "${BUILD_PATH}/php-${APP_VERSION}/sapi/fpm/www.conf" ]; then
    cp "${BUILD_PATH}/php-${APP_VERSION}/sapi/fpm/www.conf" "${PHP_INSTALL_PATH}/etc/php-fpm.d/www.conf"
else
    cp "${PHP_INSTALL_PATH}/etc/php-fpm.d/www.conf.default" "${PHP_INSTALL_PATH}/etc/php-fpm.d/www.conf"
fi

ensure_dir /var/log/php
sed -i "s#;pid = run/php-fpm.pid#pid = ${PHP_FPM_PID}#g" "${PHP_INSTALL_PATH}/etc/php-fpm.conf"
sed -i "s#;error_log = log/php-fpm.log#error_log = ${PHP_ERROR_LOG}#g" "${PHP_INSTALL_PATH}/etc/php-fpm.conf"
sed -i "s#listen = 127.0.0.1:9000#listen = ${PHP_FPM_SOCK}#g" "${PHP_INSTALL_PATH}/etc/php-fpm.d/www.conf"
sed -i "s#;listen.mode = 0660#listen.mode = 0666#g" "${PHP_INSTALL_PATH}/etc/php-fpm.d/www.conf"
# php_admin_value[error_log]
sed -i "s#;php_admin_value\[error_log\] = log/php-fpm.log#php_admin_value[error_log] = ${PHP_FPM_ERROR_LOG}#g" "${PHP_INSTALL_PATH}/etc/php-fpm.d/www.conf"
# default www
cat > "${PHP_INSTALL_PATH}/etc/php-fpm.d/www.conf" <<EOF
[www]
user = www
group = www
listen = ${PHP_FPM_SOCK}
;listen.backlog = 511
listen.owner = www
listen.group = www
listen.mode = 0666
;listen.allowed_clients = 127.0.0.1

pm = ondemand
pm.max_children = 2
;pm.process_idle_timeout = 10s;
pm.max_requests = 500

env[HOSTNAME] = $HOSTNAME
env[PATH] = /usr/local/bin:/usr/bin:/bin
env[TEMP] = /tmp
env[TMP] = /tmp
env[TMPDIR] = /tmp

EOF


# ── systemd / init.d 服务 ─────────────────────────────────
if command -v systemctl >/dev/null 2>&1; then
    if [ -f "${BUILD_PATH}/php-${APP_VERSION}/sapi/fpm/php-fpm.service" ]; then
        cp "${BUILD_PATH}/php-${APP_VERSION}/sapi/fpm/php-fpm.service" "/etc/systemd/system/php-fpm-${PHP_SHORT_VERSION}.service"
    else
        # 生成最小服务单元（部分发行版源码不含 php-fpm.service）
        cat > "/etc/systemd/system/php-fpm-${PHP_SHORT_VERSION}.service" <<EOF
[Unit]
Description=The PHP FastCGI Process Manager (PHP ${PHP_VERSION})
After=network.target

[Service]
Type=forking
ExecStart=${PHP_INSTALL_PATH}/sbin/php-fpm -y ${PHP_INSTALL_PATH}/etc/php-fpm.conf
ExecReload=/bin/kill -USR2 \\$MAINPID
PrivateTmp=false

[Install]
WantedBy=multi-user.target
EOF
    fi
    sed -i "s#^PrivateTmp=true#PrivateTmp=false#g" "/etc/systemd/system/php-fpm-${PHP_SHORT_VERSION}.service"
    systemctl daemon-reload
    systemctl enable "php-fpm-${PHP_SHORT_VERSION}.service"
    systemctl start "php-fpm-${PHP_SHORT_VERSION}.service"
elif command -v chkconfig >/dev/null 2>&1; then
    if [ -f "${BUILD_PATH}/php-${APP_VERSION}/sapi/fpm/init.d.php-fpm" ]; then
        cp "${BUILD_PATH}/php-${APP_VERSION}/sapi/fpm/init.d.php-fpm" "/etc/init.d/php-fpm-${PHP_SHORT_VERSION}"
        chmod +x "/etc/init.d/php-fpm-${PHP_SHORT_VERSION}"
    fi
    chkconfig --add "php-fpm-${PHP_SHORT_VERSION}"
    chkconfig "php-fpm-${PHP_SHORT_VERSION}" on
    service "php-fpm-${PHP_SHORT_VERSION}" start
fi

# ── 全局命令链接（表单选项 SET_DEFAULT=true 时注册为系统全局默认）──
# SET_DEFAULT 由安装表单「设为全局默认 PHP」开关注入（true / false）。
# 缺省按 true 处理，兼容旧版直接执行或快照未含该选项的安装（历史行为为无条件注册）。
if [ "${SET_DEFAULT:-true}" = "true" ]; then
    ln -sf "${PHP_INSTALL_PATH}/bin/php" /usr/local/bin/php
    ln -sf "${PHP_INSTALL_PATH}/bin/php-cgi" /usr/local/bin/php-cgi
    ln -sf "${PHP_INSTALL_PATH}/bin/pear" /usr/local/bin/pear
    ln -sf "${PHP_INSTALL_PATH}/bin/pecl" /usr/local/bin/pecl
    if [ ! -e /usr/bin/php ]; then
        ln -s "${PHP_INSTALL_PATH}/bin/php" /usr/bin/php
    fi
    log_info "已将 PHP ${PHP_VERSION} 注册为全局默认（/usr/local/bin）"
else
    log_info "未勾选「设为默认」，跳过 /usr/local/bin 注册，保留现有默认版本"
fi

# ── 登记实例信息(apps/<category>/<name>/info.yaml,供「已安装」展示)──────
# svc_name=php-fpm-<主次拼接>(如 php-fpm-85,systemd unit 同名),状态探测与
# 面板启停走 systemctl;pid_file 保留,作为无 systemd(chkconfig) 环境兜底探活。
ensure_dir "${APP_PATH}"
cat > "${APP_PATH}/info.yaml" <<EOF
svc_name: php-fpm-${PHP_SHORT_VERSION}
instance: php${PHP_SHORT_VERSION}
install_dir: ${PHP_INSTALL_PATH}
config_file: ${PHP_INSTALL_PATH}/etc/php.ini
config_files:
  - path: ${PHP_INSTALL_PATH}/etc/php.ini
    label: php.ini
  - path: ${PHP_INSTALL_PATH}/etc/php-fpm.conf
    label: php-fpm.conf
  - path: ${PHP_INSTALL_PATH}/etc/php-fpm.d/www.conf
    label: php-fpm.d/www.conf(FPM Pool)
pid_file: ${PHP_FPM_PID}
expose: unix:${PHP_FPM_SOCK}
tags:
  - php
  - runtime
EOF

log_info "PHP ${APP_VERSION} installing successful"
