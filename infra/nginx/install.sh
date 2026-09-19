#!/bin/bash
#=============================================================================
# Nginx 常规编译安装脚本(zap appstore 调用,root 执行)
#
# 特性:
#   * 依赖源码(zlib / pcre2 / openssl)全部编译进 nginx,运行时仅依赖 glibc;
#   * OpenSSL 一律走源码捆绑编译(默认 3.5.6,可用 OPENSSL_VERSION 覆盖),
#     不依赖系统 libssl 版本;
#   * 覆盖常规模块:http ssl/v2/realip/addition/sub/dav/flv/mp4/gunzip/
#     gzip_static/auth_request/random_index/secure_link/slice/stub_status,
#     stream(含 ssl/ssl_preread/realip/slice)、threads、file-aio;
#   * 兼容安装选项 options(动作 build):MODULES / EXTRA_CONFIG 追加到 configure;
#   * 修复 systemd 模板硬编码路径:按实际安装目录生成 nginx.service;
#   * 登记 info.yaml(svc_name=nginx),Web 端「已安装」可启停/查看状态。
#
# 依赖环境变量(由 zapexec 注入):ZAP_PATH ZAPCTL APPS_DIR PKG_PATH APP_PATH
#   APP_ID APP_NAME APP_VERSION BUILD_PATH CPU_NUM [MAJOR_VERSION MINOR_VERSION]
#
# 可覆盖(环境变量):
#   OPENSSL_VERSION= 捆绑编译的 OpenSSL 源码版本  默认 3.5.6
#   OPENSSL_SRC_DIR= 已有 openssl 源码树路径(优先使用,跳过下载)
#   ZLIB_VERSION   / PCRE2_VERSION              默认 1.3.1 / 10.48
#   NGINX_MIRROR   = 镜像 base                  默认 https://mirrors.zap.cn/pkg
#=============================================================================
set -euo pipefail

source "${ZAP_PATH}/scripts/zap/bash_utils.sh"

# ── 可配置常量 ────────────────────────────────────────────────────────────
NGINX_MIRROR="${NGINX_MIRROR:-https://mirrors.zap.cn/pkg}"
ZLIB_VERSION="${ZLIB_VERSION:-1.3.1}"
PCRE2_VERSION="${PCRE2_VERSION:-10.48}"
OPENSSL_VERSION="${OPENSSL_VERSION:-3.5.6}"

INSTALL_PATH="${APPS_DIR}/nginx-${APP_VERSION}"
NGINX_SRC="nginx-${APP_VERSION}"
ZLIB_SRC="zlib-${ZLIB_VERSION}"
PCRE2_SRC="pcre2-${PCRE2_VERSION}"
OPENSSL_SRC="openssl-${OPENSSL_VERSION}"

# ── 前置:用户 / 目录 / 首次系统依赖 ─────────────────────────────────────
prepare_install_env www

# 编译目标目录需为 zapexec 按本次运行注入的专属路径(runs/<run_id>/build,
# run_id 动态,故按前缀模式校验);异常时拒绝清理,避免误删
if [[ "${BUILD_PATH}" != "${ZAP_PATH}/data/appstore/runs/"*"/build" ]]; then
    log_error "BUILD_PATH 异常(${BUILD_PATH}),拒绝清理"
    exit 1
fi
rm -rf "${BUILD_PATH}"
ensure_dir "${BUILD_PATH}" "${APP_PATH}"
cd "${PKG_PATH}"

# ── 下载依赖源码(失败即退出) ─────────────────────────────────────────────
log_info "下载/校验依赖源码 ..."
if [ ! -f "${NGINX_SRC}.tar.gz" ]; then
    log_info "download nginx-${APP_VERSION}"
    fetch_file "${NGINX_MIRROR}/nginx/${NGINX_SRC}.tar.gz" "${NGINX_SRC}.tar.gz" || exit 1
fi
if [ ! -f "${ZLIB_SRC}.tar.gz" ]; then
    log_info "download ${ZLIB_SRC}"
    fetch_file "${NGINX_MIRROR}/zlib/${ZLIB_SRC}.tar.gz" "${ZLIB_SRC}.tar.gz" || exit 1
fi
if [ ! -f "${PCRE2_SRC}.tar.gz" ]; then
    log_info "download ${PCRE2_SRC}"
    fetch_file "${NGINX_MIRROR}/pcre2/${PCRE2_SRC}.tar.gz" "${PCRE2_SRC}.tar.gz" || exit 1
fi
if [ ! -f "${OPENSSL_SRC}.tar.gz" ]; then
    log_info "download ${OPENSSL_SRC}"
    fetch_file "${NGINX_MIRROR}/openssl/${OPENSSL_SRC}.tar.gz" "${OPENSSL_SRC}.tar.gz" || exit 1
fi

# ── 解压 nginx / zlib / pcre2 ─────────────────────────────────────────────
log_info "解压源码包 ..."
tar -xzf "${ZLIB_SRC}.tar.gz" -C "${BUILD_PATH}"
tar -xzf "${NGINX_SRC}.tar.gz" -C "${BUILD_PATH}"
tar -xzf "${PCRE2_SRC}.tar.gz" -C "${BUILD_PATH}"
tar -xzf "${OPENSSL_SRC}.tar.gz" -C "${BUILD_PATH}"

# ── 清理旧的同版本安装残留 ───────────────────────────────────────────────
if [ -d "${INSTALL_PATH}" ]; then
    log_warn "检测到已存在 ${INSTALL_PATH},备份 conf 后重新安装"
    if [ -d "${INSTALL_PATH}/conf" ]; then
        ensure_dir /root/zap_bak/nginx
        cp -Rf "${INSTALL_PATH}/conf" "/root/zap_bak/nginx/conf.$(date +%Y%m%d%H%M%S)" || true
    fi
    rm -rf "${INSTALL_PATH}"
fi

# ── configure:常规模块 + 依赖 ─────────────────────────────────────────────
log_info "开始编译 nginx-${APP_VERSION}(OpenSSL ${OPENSSL_VERSION}) ..."
cd "${BUILD_PATH}/${NGINX_SRC}"

configure_args=(
    --user=www
    --group=www
    --prefix="${INSTALL_PATH}"
    --pid-path=/var/run/nginx.pid
    --error-log-path=/var/log/nginx/error.log
    --http-log-path=/var/log/nginx/access.log
    # http 常规模块
    --with-http_ssl_module
    --with-http_v2_module
    --with-http_realip_module
    --with-http_addition_module
    --with-http_sub_module
    --with-http_dav_module
    --with-http_flv_module
    --with-http_mp4_module
    --with-http_gunzip_module
    --with-http_gzip_static_module
    --with-http_auth_request_module
    --with-http_random_index_module
    --with-http_secure_link_module
    --with-http_slice_module
    --with-http_stub_status_module
    # 常规流媒体 / 基础
    --with-threads
    --with-file-aio
    # stream(TCP/UDP 反代)
    --with-stream
    --with-stream_ssl_module
    --with-stream_ssl_preread_module
    --with-stream_realip_module
    # 依赖(源码树编译)
    --with-pcre="${BUILD_PATH}/${PCRE2_SRC}"
    --with-zlib="${BUILD_PATH}/${ZLIB_SRC}"
    --with-openssl="${BUILD_PATH}/${OPENSSL_SRC}"
    --with-openssl-opt=no-async
)

# 安装选项(用户从 options 表单提交):MODULES(multiselect,空格分隔)/ EXTRA_CONFIG(string)
# 追加到 configure 参数末尾
if [ -n "${EXTRA_CONFIG:-}" ]; then
    read -r -a extra_args <<< "${EXTRA_CONFIG}"
    configure_args+=("${extra_args[@]}")
fi
if [ -n "${MODULES:-}" ]; then
    read -r -a module_args <<< "${MODULES}"
    configure_args+=("${module_args[@]}")
fi

log_info "configure ..."
./configure "${configure_args[@]}"
log_ok "configure 完成,开始 make(并行 ${CPU_NUM:-auto})"
make -j "${CPU_NUM:-$(cpu_count)}"
make install
if [ ! -x "${INSTALL_PATH}/sbin/nginx" ]; then
    log_error "make install 未产出 nginx 二进制,安装失败"
    exit 1
fi
log_ok "nginx 编译安装完成: ${INSTALL_PATH}"

# ── 配置目录 / 默认站点 / dhparam ────────────────────────────────────────
ensure_dir "${INSTALL_PATH}/conf/conf.d" "${INSTALL_PATH}/conf/sites-enabled" /var/log/nginx

if [ ! -f "${INSTALL_PATH}/conf/dhparam.pem" ]; then
    log_info "生成 dhparam.pem(2048,可能需要几秒)..."
    openssl dhparam -out "${INSTALL_PATH}/conf/dhparam.pem" 2048 || true
fi

cp -f "${ZAP_PATH}/scripts/zap/conf/nginx.conf" "${INSTALL_PATH}/conf/nginx.conf"
if [ ! -f "${INSTALL_PATH}/conf/sites-enabled/default.conf" ]; then
    cp -f "${ZAP_PATH}/scripts/zap/conf/default.conf" "${INSTALL_PATH}/conf/sites-enabled/default.conf"
fi
# 确保模板引用的 mime.types 存在(make install 通常已生成)
if [ ! -f "${INSTALL_PATH}/conf/mime.types" ] && [ -f "${BUILD_PATH}/${NGINX_SRC}/conf/mime.types" ]; then
    cp -f "${BUILD_PATH}/${NGINX_SRC}/conf/mime.types" "${INSTALL_PATH}/conf/mime.types"
fi

# ── 版本软链 ──────────────────────────────────────────────────────────────
if [ -L "${APPS_DIR}/nginx" ]; then
    rm -f "${APPS_DIR}/nginx"
    ln -s "${INSTALL_PATH}" "${APPS_DIR}/nginx"
    log_ok "更新软链 ${APPS_DIR}/nginx -> ${INSTALL_PATH}"
elif [ -e "${APPS_DIR}/nginx" ] && [ ! -d "${APPS_DIR}/nginx" ]; then
    rm -f "${APPS_DIR}/nginx"
    ln -s "${INSTALL_PATH}" "${APPS_DIR}/nginx"
elif [ ! -e "${APPS_DIR}/nginx" ]; then
    ln -s "${INSTALL_PATH}" "${APPS_DIR}/nginx"
    log_ok "创建软链 ${APPS_DIR}/nginx -> ${INSTALL_PATH}"
else
    log_warn "${APPS_DIR}/nginx 已存在真实目录,跳过软链(服务仍指向 ${INSTALL_PATH})"
fi

# ── 服务(修正模板中的硬编码路径,按实际安装目录生成) ────────────────────
# 说明:若先配置过站点需额外测试 nginx -t;此处直接写精确路径。
SVC_CMD=""
if command -v systemctl >/dev/null 2>&1; then
    log_info "生成 systemd 服务 nginx.service(路径: ${INSTALL_PATH})"
    sed "s|/usr/local/apps/nginx|${INSTALL_PATH}|g" \
        "${ZAP_PATH}/scripts/systemd/nginx.service" > /etc/systemd/system/nginx.service
    chmod 644 /etc/systemd/system/nginx.service
    systemctl daemon-reload
    systemctl enable nginx.service >/dev/null 2>&1 || true
    if ! systemctl start nginx.service; then
        log_error "systemctl start nginx 失败,执行 nginx -t 诊断:"
        "${INSTALL_PATH}/sbin/nginx" -t || true
    fi
    SVC_CMD="systemctl"
else
    log_warn "未检测到 systemd,尝试 service nginx start"
    if command -v service >/dev/null 2>&1; then
        service nginx start || true
        SVC_CMD="service"
    fi
fi
sleep 1

# ── 更新 zap 应用表(面板展示状态/可启停依赖 info.yaml) ──────────────────
# info.yaml 写入 APP_PATH(apps/<category>/<name>/),供 zapexec 探测与启停
cat > "${APP_PATH}/info.yaml" <<'YAML'
svc_name: nginx
instance: nginx
install_dir: __INSTALL_PATH__
config_file: __INSTALL_PATH__/conf/nginx.conf
config_files:
  - path: __INSTALL_PATH__/conf/nginx.conf
    label: nginx.conf（主配置）
  - path: __INSTALL_PATH__/conf/sites-enabled/default.conf
    label: sites-enabled/default.conf（默认站点）
pid_file: /var/run/nginx.pid
expose: tcp:80
tags:
  - webserver
YAML
sed -i "s|__INSTALL_PATH__|${INSTALL_PATH}|g" "${APP_PATH}/info.yaml"

log_ok "nginx-${APP_VERSION} 安装完成(${INSTALL_PATH}),命令: ${SVC_CMD:-无} start/stop/restart"
if [ -n "${SVC_CMD}" ] && command -v systemctl >/dev/null 2>&1; then
    if [ "$(systemctl is-active nginx.service)" != "active" ]; then
        log_warn "nginx 服务当前未运行,请检查上方 nginx -t 输出"
    fi
fi
