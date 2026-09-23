#!/bin/bash
# PCRE2 库安装脚本（zap appstore 调用，源码编译）
# 依赖环境变量（由 zapexec 注入）：ZAP_PATH APPS_DIR PKG_PATH APP_PATH APP_VERSION MAJOR_VERSION MINOR_VERSION BUILD_PATH CPU_NUM
set -euo pipefail

source "${ZAP_PATH}/scripts/zap/bash_utils.sh"

S_VERSION="${MAJOR_VERSION}.${MINOR_VERSION}"
INSTALL_PATH="${APPS_DIR}/libpcre2-${S_VERSION}"

cd "${PKG_PATH}"
if [ ! -f "pcre2-${APP_VERSION}.tar.gz" ]; then
    # 统一走 bash_utils 下载器(curl -fsSL 静默优先、wget -q 回退,失败自动重试),
    # 避免裸 wget 的进度条刷屏;文件已存在(同快照内重跑)则跳过下载
    download_file "$(pkg_mirror)/pcre2/pcre2-${APP_VERSION}.tar.gz" \
        "pcre2-${APP_VERSION}.tar.gz"
fi

rm -rf "${BUILD_PATH}"
mkdir -p "${BUILD_PATH}"
tar zxf "pcre2-${APP_VERSION}.tar.gz" -C "${BUILD_PATH}"
cd "${BUILD_PATH}/pcre2-${APP_VERSION}"

./configure --prefix="${INSTALL_PATH}" --enable-pcre2-8 --enable-unicode
make -j "${CPU_NUM:-1}" && make install

if [ ! -d "${INSTALL_PATH}" ]; then
    echo "libpcre2 ${APP_VERSION} Install failed"
    exit 1
fi

mkdir -p /usr/local/lib/pkgconfig
ln -sf "${INSTALL_PATH}/lib/pkgconfig/libpcre2-8.pc" /usr/local/lib/pkgconfig/libpcre2-8.pc

# ── 登记实例信息(apps/<category>/<name>/info.yaml,供「已安装」展示)──────
# 说明:运行元数据(version/run_id/installed_at...)由 zapexec 写入同目录
# meta.yaml;本应用为无守护进程的静态库,故不写 svc_name/pid_file
# (状态由 zapexec 返回 unknown)。
ensure_dir "${APP_PATH}"
cat > "${APP_PATH}/info.yaml" <<EOF
instance: libpcre2${S_VERSION}
install_dir: ${INSTALL_PATH}
config_file: ${INSTALL_PATH}/lib/pkgconfig/libpcre2-8.pc
expose: none
tags:
  - library
  - regex
EOF
echo "libpcre2 ${APP_VERSION} installing successful"
