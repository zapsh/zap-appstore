#!/bin/bash
# Docker 安装脚本（zap appstore 调用）
#
# 依赖环境变量（由 zapexec 注入）：ZAP_PATH APPS_DIR PKG_PATH APP_PATH APP_VERSION
# 可选（options，值原样注入为同名环境变量）：
#   INSTALL_MIRROR    select —— official（get.docker.com，默认）/ aliyun（--mirror Aliyun）
#   INSTALL_CHANNEL   select —— stable（默认）/ test / nightly，Docker 发布通道
#   REGISTRY_MIRROR   string —— 镜像加速器地址，写入 /etc/docker/daemon.json
#   DATA_ROOT         string —— 数据目录，默认 /var/lib/docker
#   ENABLE_SERVICE    bool   —— "true" 时设置开机自启并立即启动（默认 true）
#   JOIN_DOCKER_GROUP string —— 逗号分隔的用户名，加入 docker 组以去掉 sudo
#
# 说明：
#   * 走 Docker 官方便捷脚本 get-docker.sh 安装：自动识别发行版并调用系统包管理器，
#     比手工拼 apt/yum 的 docker-ce 版本字符串（含 5:28.5.1-1~ubuntu.24.04~noble 这种
#     发行版相关后缀）可靠得多，且天然兼容 Ubuntu/Debian/RHEL 系。
#   * systemd / openrc / sysvinit 三种 init 均会尝试设置开机自启。
#   * 重复安装安全：zap 升级流程为「先 uninstall 再 install」，脚本可重复执行。
set -euo pipefail

source "${ZAP_PATH}/scripts/zap/bash_utils.sh"

assert_root || exit 1

INSTALL_MIRROR="${INSTALL_MIRROR:-official}"
INSTALL_CHANNEL="${INSTALL_CHANNEL:-stable}"
REGISTRY_MIRROR="${REGISTRY_MIRROR:-}"
DATA_ROOT="${DATA_ROOT:-/var/lib/docker}"
ENABLE_SERVICE="${ENABLE_SERVICE:-true}"
JOIN_DOCKER_GROUP="${JOIN_DOCKER_GROUP:-}"

# bash_utils 被 source 时已执行 os_detect，以下变量可直接用
log_info "系统：${OS_PRETTY:-${OS_NAME:-unknown}}，架构：${OS_ARCH_ALIAS:-${OS_ARCH:-unknown}}"

# ── 已安装检查（升级流程会先 uninstall 再 install，属正常）──
if command -v docker >/dev/null 2>&1; then
    log_warn "检测到已存在 docker：$(docker --version 2>/dev/null || echo unknown)，将覆盖安装"
fi

# ── 下载官方便捷安装脚本 ───────────────────────────────────
INST_TMP="$(mktemp -d)"
trap 'rm -rf "${INST_TMP}"' EXIT

MIRROR_ARG=""
case "${INSTALL_MIRROR}" in
    aliyun)
        MIRROR_ARG="--mirror Aliyun"
        log_info "安装源：阿里云镜像（get.docker.com --mirror Aliyun）"
        ;;
    official)
        log_info "安装源：官方（get.docker.com）"
        ;;
    *)
        log_warn "未知安装源「${INSTALL_MIRROR}」，回退官方源"
        ;;
esac

log_info "下载 Docker 安装脚本…"
download_file "https://get.docker.com" "${INST_TMP}/get-docker.sh"

# ── 版本 / 通道 ───────────────────────────────────────────
# APP_VERSION 为 latest（或空）时不指定 VERSION，由脚本装该通道最新版
INSTALL_VERSION=""
if [ "${APP_VERSION:-latest}" = "latest" ] || [ -z "${APP_VERSION:-}" ]; then
    log_info "安装目标：${INSTALL_CHANNEL} 通道最新版"
else
    INSTALL_VERSION="${APP_VERSION}"
    log_info "安装目标：${INSTALL_VERSION}（${INSTALL_CHANNEL} 通道）"
fi

log_info "开始安装 Docker（约需 1–3 分钟）…"
# shellcheck disable=SC2086
if ! VERSION="${INSTALL_VERSION}" CHANNEL="${INSTALL_CHANNEL}" \
        sh "${INST_TMP}/get-docker.sh" ${MIRROR_ARG}; then
    log_error "Docker 安装失败"
    log_error "国内网络可把「安装源」改为 aliyun 后重试"
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    log_error "Docker 安装失败：未找到 docker 命令"
    exit 1
fi

# ── daemon.json（仅在有自定义项时才写）────────────────────
DAEMON_JSON="/etc/docker/daemon.json"
ENTRIES=()

if [ "${DATA_ROOT}" != "/var/lib/docker" ]; then
    ensure_dir "${DATA_ROOT}"
    ENTRIES+=("  \"data-root\": \"${DATA_ROOT}\"")
    log_info "数据目录：${DATA_ROOT}"
fi
if [ -n "${REGISTRY_MIRROR}" ]; then
    ENTRIES+=("  \"registry-mirrors\": [\"${REGISTRY_MIRROR}\"]")
    log_info "镜像加速器：${REGISTRY_MIRROR}"
fi

DAEMON_WRITTEN="no"
if [ "${#ENTRIES[@]}" -gt 0 ]; then
    ensure_dir /etc/docker
    if [ -f "${DAEMON_JSON}" ]; then
        BAK="${DAEMON_JSON}.zapbak.$(date +%Y%m%d%H%M%S)"
        cp -a "${DAEMON_JSON}" "${BAK}"
        log_warn "已存在 ${DAEMON_JSON}，备份为 ${BAK} 后覆盖；原有自定义项请手动合并"
    fi
    {
        printf '{\n'
        FIRST=1
        for E in "${ENTRIES[@]}"; do
            if [ "${FIRST}" -eq 1 ]; then
                FIRST=0
            else
                printf ',\n'
            fi
            printf '%s' "${E}"
        done
        printf '\n}\n'
    } > "${DAEMON_JSON}"
    DAEMON_WRITTEN="yes"
    log_info "已写入 ${DAEMON_JSON}"
else
    log_info "无需自定义配置，跳过 daemon.json"
fi

# ── 开机自启与启动 ─────────────────────────────────────────
if [ "${ENABLE_SERVICE}" = "true" ]; then
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        if systemctl enable --now docker >/dev/null 2>&1; then
            log_info "已设置开机自启并启动 docker（systemd）"
        else
            log_warn "systemctl enable --now docker 失败，请手动执行：systemctl enable --now docker"
        fi
    elif command -v rc-update >/dev/null 2>&1; then
        rc-update add docker default >/dev/null 2>&1 || true
        if rc-service docker start >/dev/null 2>&1 || service docker start >/dev/null 2>&1; then
            log_info "已设置开机自启并启动 docker（openrc）"
        else
            log_warn "docker 启动失败，请手动执行：rc-service docker start"
        fi
    elif command -v service >/dev/null 2>&1; then
        service docker start >/dev/null 2>&1 || true
        log_info "已尝试启动 docker（sysvinit）"
    else
        log_warn "未识别的 init 系统，请手动启动 docker"
    fi
else
    log_info "按要求未设置开机自启（ENABLE_SERVICE=false）"
fi

# ── 免 sudo：把用户加入 docker 组 ──────────────────────────
if [ -n "${JOIN_DOCKER_GROUP}" ]; then
    if ! ensure_group docker; then
        log_warn "docker 组不可用，跳过加入用户"
    else
        IFS=',' read -ra GRANT_USERS <<< "${JOIN_DOCKER_GROUP}" || true
        for U in "${GRANT_USERS[@]}"; do
            U="$(printf '%s' "${U}" | tr -d '[:space:]')"
            [ -n "${U}" ] || continue
            if ! id "${U}" >/dev/null 2>&1; then
                log_warn "用户 ${U} 不存在，跳过"
                continue
            fi
            if ensure_usergroup "${U}" docker; then
                log_info "已将用户 ${U} 加入 docker 组（重新登录后生效）"
            else
                log_warn "将用户 ${U} 加入 docker 组失败"
            fi
        done
    fi
fi

# ── 验证 ───────────────────────────────────────────────────
if docker info >/dev/null 2>&1; then
    log_ok "Docker 守护进程已就绪"
else
    log_warn "docker info 未通过（守护进程可能未启动），请手动执行：systemctl start docker"
fi

VER_LINE="$(docker --version 2>/dev/null || echo unknown)"

# ── 登记实例信息（apps/<category>/<name>/info.yaml）────────
ensure_dir "${APP_PATH}"
cat > "${APP_PATH}/info.yaml" <<EOF
svc_name: docker
instance: docker
install_dir: /usr/bin
config_file: /etc/docker/daemon.json
expose:
    unix:/var/run/docker.sock
pid_file: /var/run/docker.pid
data_root: ${DATA_ROOT}
channel: ${INSTALL_CHANNEL}
version: ${APP_VERSION:-latest}
daemon_config: ${DAEMON_JSON}
daemon_written: ${DAEMON_WRITTEN}
data_root: ${DATA_ROOT}
registry_mirror: ${REGISTRY_MIRROR}
EOF

log_info "Docker 安装成功：${VER_LINE}"
