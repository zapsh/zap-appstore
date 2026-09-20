#!/bin/bash
#=============================================================================
# OpenSSL 库常规编译安装脚本(zap appstore 调用,root 执行,源码编译)
#
# 特性:
#   * 使用公共工具库 bash_utils:统一日志 / fetch_file(curl→wget 自动重试)/
#     MakeInstall(并行编译失败自动回退串行)/ cpu_count / extract_archive /
#     ensure_dir / prepare_install_env(运行用户 + 目录 + 首次系统编译依赖);
#
# 依赖环境变量(由 zapexec 注入):ZAP_PATH APPS_DIR PKG_PATH APP_PATH
#   APP_NAME APP_VERSION MAJOR_VERSION MINOR_VERSION BUILD_PATH CPU_NUM
#   (手动运行时若缺 MAJOR/MINOR,会从 APP_VERSION 自动推导)
#
# 可覆盖(环境变量):
#   OPENSSL_MIRROR      镜像 base(末尾不带斜杠)  默认 https://mirrors.zap.cn/pkg/openssl
#   OPENSSL_ENABLE_WEAK 1 | 0  仅 OpenSSL 1.1.x 生效(3.x 无此编译开关),
#                          默认 1 = 编译 enable-weak-ssl-ciphers(保持旧行为)
#   OPENSSL_EXTRA_CONFIG    额外追加给 ./config 的参数(按空格分词追加)
#=============================================================================
set -euo pipefail

source "${ZAP_PATH}/scripts/zap/bash_utils.sh"

# ── 版本与安装目录 ─────────────────────────────────────────────────────────
APP_VERSION="${APP_VERSION:-1.1.1w}"
if [ -z "${MAJOR_VERSION:-}" ]; then MAJOR_VERSION="${APP_VERSION%%.*}"; fi
if [ -z "${MINOR_VERSION:-}" ]; then _ver_rest="${APP_VERSION#*.}"; MINOR_VERSION="${_ver_rest%%.*}"; fi
SHORT_VERSION="${MAJOR_VERSION}.${MINOR_VERSION}"
INSTALL_PATH="${APPS_DIR}/openssl${SHORT_VERSION}"
OPENSSL_MIRROR="${OPENSSL_MIRROR:-https://mirrors.zap.cn/pkg/openssl}"
OPENSSL_ENABLE_WEAK="${OPENSSL_ENABLE_WEAK:-1}"
OPENSSL_EXTRA_CONFIG="${OPENSSL_EXTRA_CONFIG:-}"

log_info "Installing OpenSSL ${APP_VERSION} -> ${INSTALL_PATH}"

# ── perl 预检(OpenSSL 编译必需)────────────────────────────────────────────
_ensure_perl() {
    if ! command -v perl >/dev/null 2>&1; then
        log_warn "缺少 perl(OpenSSL 编译必需),尝试自动安装 ..."
        if is_os ubuntu debian; then
            apt-get update -y >/dev/null 2>&1 || true
            apt-get install -y perl >/dev/null 2>&1 || true
        elif is_os alpine; then
            apk add --no-cache perl >/dev/null 2>&1 || true
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y perl >/dev/null 2>&1 || true
        elif command -v yum >/dev/null 2>&1; then
            yum install -y perl >/dev/null 2>&1 || true
        fi
    fi
    if ! command -v perl >/dev/null 2>&1; then
        log_error "required perl not found,please install it first"
        return 1
    fi
    # OpenSSL 3.x 的 Configure 需要 Text::Template(1.1.x 不需要)
    if [ "${MAJOR_VERSION}" != "1" ] && ! perl -MText::Template -e 1 >/dev/null 2>&1; then
        log_warn "缺少 perl Text::Template 模块(OpenSSL 3.x Configure 需要),尝试自动安装 ..."
        if is_os ubuntu debian; then
            apt-get install -y libtext-template-perl >/dev/null 2>&1 || true
        elif is_os alpine; then
            apk add --no-cache perl-text-template >/dev/null 2>&1 || true
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y perl-Text-Template >/dev/null 2>&1 || true
        elif command -v yum >/dev/null 2>&1; then
            yum install -y perl-Text-Template >/dev/null 2>&1 || true
        fi
        if ! perl -MText::Template -e 1 >/dev/null 2>&1; then
            log_warn "Text::Template 模块安装失败;如 configure 报 'Can't locate Text/Template.pm' 请手动安装"
        fi
    fi
    return 0
}
_ensure_perl || exit 1

# ── 下载源码(已存在则跳过,失败即退出)─────────────────────────────────────
cd "${PKG_PATH}"
SRC_TGZ="openssl-${APP_VERSION}.tar.gz"
if [ ! -f "${SRC_TGZ}" ]; then
    log_info "下载 ${OPENSSL_MIRROR}/${SRC_TGZ}"
    fetch_file "${OPENSSL_MIRROR}/${SRC_TGZ}" "${SRC_TGZ}" || exit 1
fi

# ── BUILD_PATH 前缀校验,异常时拒绝清理(防误删) ────────────────────────────
if [[ "${BUILD_PATH}" != "${ZAP_PATH}/data/appstore/runs/"*"/build" ]]; then
    log_error "BUILD_PATH 异常(${BUILD_PATH}),拒绝清理"
    exit 1
fi
rm -rf "${BUILD_PATH}"
ensure_dir "${BUILD_PATH}"

log_info "解压 ${SRC_TGZ}"
extract_archive "${SRC_TGZ}" "${BUILD_PATH}" || exit 1
SRC_DIR="${BUILD_PATH}/openssl-${APP_VERSION}"
if [ ! -f "${SRC_DIR}/Configure" ]; then
    log_error "解压后未找到源码 ${SRC_DIR}/Configure,请检查归档内容"
    exit 1
fi
cd "${SRC_DIR}"

# ── configure ──────────────────────────────────────────────────────────────
# 保留旧脚本行为:-Wl,-rpath(运行时找同目录 libcrypto)、shared -fPIC;
# 补充:--openssldir 指向 <prefix>/ssl(openssl.cnf/certs/private 归位)、
#       --libdir=lib 固定库目录。
config_args=(
    "-Wl,-rpath=${INSTALL_PATH}/lib"
    "--prefix=${INSTALL_PATH}"
    "--openssldir=${INSTALL_PATH}/ssl"
    "--libdir=lib"
    shared
    -fPIC
)
# 弱加密开关仅 OpenSSL 1.1.x 提供,3.x 无此编译选项(传了会 configure 失败)
if [ "${MAJOR_VERSION}" = "1" ] && [ "${OPENSSL_ENABLE_WEAK}" = "1" ]; then
    config_args+=(enable-weak-ssl-ciphers)
fi
# 外部扩展参数(如 no-asm / threads 等)
if [ -n "${OPENSSL_EXTRA_CONFIG}" ]; then
    read -r -a _extra <<< "${OPENSSL_EXTRA_CONFIG}"
    config_args+=("${_extra[@]}")
fi

log_info "configure OpenSSL-${APP_VERSION} ..."
./config "${config_args[@]}"
log_ok "configure 完成,开始编译(并行 ${CPU_NUM:-auto},失败自动回退串行)"

# 并行编译失败自动退回串行(OpenSSL 编译较吃内存,低内存机器可避免反复失败)
MakeInstall

if [ ! -x "${INSTALL_PATH}/bin/openssl" ]; then
    log_error "MakeInstall failed"
    exit 1
fi
log_ok "Completed: ${INSTALL_PATH}"

# ── ssl 数据目录兜底(openssl.cnf / certs / private)───────────────────────
ensure_dir "${INSTALL_PATH}/ssl"
if [ ! -f "${INSTALL_PATH}/ssl/openssl.cnf" ]; then
    if [ -f "${SRC_DIR}/apps/openssl.cnf" ]; then
        cp -f "${SRC_DIR}/apps/openssl.cnf" "${INSTALL_PATH}/ssl/openssl.cnf"
    elif [ -f "${SRC_DIR}/openssl.cnf" ]; then
        cp -f "${SRC_DIR}/openssl.cnf" "${INSTALL_PATH}/ssl/openssl.cnf"
    else
        log_warn "未找到 openssl.cnf 模板,请手动放置到 ${INSTALL_PATH}/ssl/"
    fi
fi



# 编译期选择版本请显式指定:
#   export PKG_CONFIG_PATH=<prefix>/lib/pkgconfig  (PHP >= 8.1 必须,走 pkg-config)
#   ./configure --with-openssl=<prefix>            (PHP 7.x 支持 DIR 前缀形式)
#   pkg-config --cflags --libs openssl             (临时单次使用,加 PKG_CONFIG_PATH)

# register ld.so.conf
if [ "${MAJOR_VERSION}" != "1" ]; then
    ensure_dir /etc/ld.so.conf.d
    printf '%s\n' "${INSTALL_PATH}/lib" > "/etc/ld.so.conf.d/zap-openssl-${MAJOR_VERSION}.conf"
    ldconfig >/dev/null 2>&1 || log_warn "ldconfig 执行失败,请手动执行 ldconfig"
fi


# ── 版本自检 ───────────────────────────────────────────────────────────────
log_info "openssl 版本: $("${INSTALL_PATH}/bin/openssl" version)"
log_info "openssl 数据目录: $("${INSTALL_PATH}/bin/openssl" version -d)"


# register instance info
ensure_dir "${APP_PATH}"
cat > "${APP_PATH}/info.yaml" <<EOF
instance: openssl${SHORT_VERSION}
install_dir: ${INSTALL_PATH}
version: ${APP_VERSION}
config_file: ${INSTALL_PATH}/ssl/openssl.cnf
expose: none
tags:
  - library
  - crypto
dependencies:
  - openssl${SHORT_VERSION}
EOF
log_info "已登记实例信息: ${APP_PATH}/info.yaml"

log_ok "openssl ${APP_VERSION} 安装成功"
