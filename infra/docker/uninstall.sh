#!/bin/bash
# Docker 卸载脚本（zap appstore 调用）
#
# 依赖环境变量（由 zapexec 注入）：ZAP_PATH APPS_DIR PKG_PATH APP_PATH
# 可选（options，值原样注入为同名环境变量）：
#   PURGE_DATA    bool —— "true" 时删除 /var/lib/docker 与 /var/lib/containerd（默认 false，保留数据）
#   BACKUP_CONFIG bool —— "true" 时先把 /etc/docker/daemon.json 备份到 /root/zap_bak/docker/（默认 true）
#
# 说明：
#   * 按发行版调用系统包管理器 purge/remove，再清理配置与（可选）数据目录。
#   * 数据目录默认保留：镜像 / 容器 / 数据卷的删除不可逆，需用户显式勾选。
#   * docker 组默认保留，避免影响系统里其它依赖该组的配置。
set -euo pipefail

source "${ZAP_PATH}/scripts/zap/bash_utils.sh"

assert_root || exit 1

PURGE_DATA="${PURGE_DATA:-false}"
BACKUP_CONFIG="${BACKUP_CONFIG:-true}"

# 便捷脚本安装时使用的包名（发行版不同略有差异，未安装的会被包管理器忽略）
DOCKER_PKGS="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras"

log_info "系统：${OS_PRETTY:-${OS_NAME:-unknown}}"

# ── 停止并禁用服务 ─────────────────────────────────────────
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemctl stop docker docker.socket containerd >/dev/null 2>&1 || true
    systemctl disable docker docker.socket containerd >/dev/null 2>&1 || true
    log_info "已停止并禁用 docker 服务（systemd）"
elif command -v rc-service >/dev/null 2>&1; then
    rc-service docker stop >/dev/null 2>&1 || true
    rc-update del docker default >/dev/null 2>&1 || true
    log_info "已停止 docker 服务（openrc）"
elif command -v service >/dev/null 2>&1; then
    service docker stop >/dev/null 2>&1 || true
    log_info "已停止 docker 服务（sysvinit）"
else
    log_warn "未识别的 init 系统，跳过停服"
fi

# ── 备份 daemon.json（含安装期覆盖产生的 .zapbak.*）────────
if [ "${BACKUP_CONFIG}" = "true" ]; then
    BAK_DIR="/root/zap_bak/docker"
    if [ -f /etc/docker/daemon.json ]; then
        ensure_dir "${BAK_DIR}"
        cp -a /etc/docker/daemon.json "${BAK_DIR}/daemon.json.$(date +%Y%m%d%H%M%S)"
        log_info "已备份 daemon.json 到 ${BAK_DIR}/"
    fi
    # 安装时覆盖配置留下的 .zapbak.* 一并归档，避免随 /etc/docker 一起消失
    if compgen -G "/etc/docker/daemon.json.zapbak.*" >/dev/null 2>&1; then
        ensure_dir "${BAK_DIR}"
        cp -a /etc/docker/daemon.json.zapbak.* "${BAK_DIR}/" 2>/dev/null || true
        log_info "已归档安装期产生的 daemon.json.zapbak.* 到 ${BAK_DIR}/"
    fi
fi

# ── 装的是 Podman 时走对应分支（两个运行时二选一）──────────
#
# 判定：系统里只有 podman、没有 docker —— 安装时选了 Podman 的情况。
# 数据目录默认同样保留（/var/lib/containers），需勾选 PURGE_DATA 才删。
if ! command -v docker >/dev/null 2>&1 && command -v podman >/dev/null 2>&1; then
    log_info "检测到 Podman（未装 Docker），按 Podman 流程卸载…"
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl stop podman.socket podman.service >/dev/null 2>&1 || true
        systemctl disable podman.socket podman.service >/dev/null 2>&1 || true
        log_info "已停止并禁用 podman.socket（systemd）"
    fi
    if is_os ubuntu debian; then
        apt-get purge -y podman podman-compose >/dev/null 2>&1 \
            || log_warn "部分包 purge 失败（可能未安装），继续清理残留"
        apt-get autoremove -y --purge >/dev/null 2>&1 || true
    elif is_os centos rhel rocky alma ol amazon fedora; then
        if command -v dnf >/dev/null 2>&1; then PM="dnf"; else PM="yum"; fi
        ${PM} remove -y podman podman-compose >/dev/null 2>&1 \
            || log_warn "部分包移除失败（可能未安装），继续清理残留"
    elif is_os alpine; then
        apk del podman >/dev/null 2>&1 \
            || log_warn "部分包移除失败（可能未安装），继续清理残留"
    else
        log_warn "未识别的发行版（${OS_NAME:-unknown}），跳过包管理器卸载，仅清理文件"
    fi
    rm -f /run/podman/podman.sock 2>/dev/null || true
    if [ "${PURGE_DATA}" = "true" ]; then
        for D in /var/lib/containers /var/lib/containers/storage; do
            if [ -e "${D}" ]; then
                rm -rf "${D}"
                log_warn "已删除：${D}（镜像 / 容器 / 数据卷不可恢复）"
            fi
        done
    elif [ -d /var/lib/containers ]; then
        log_info "按要求保留 /var/lib/containers（镜像与容器数据仍在）"
    fi
    log_info "提示：面板「系统 → 运行环境」里的「容器运行时」如已设为 podman，请改回 auto 或 docker"
    log_ok "Podman 已卸载"
    exit 0
fi

# ── 卸载软件包 ─────────────────────────────────────────────
if is_os ubuntu debian; then
    if command -v apt-get >/dev/null 2>&1; then
        log_info "apt purge Docker 相关包…"
        # shellcheck disable=SC2086
        apt-get purge -y ${DOCKER_PKGS} >/dev/null 2>&1 \
            || log_warn "部分包 purge 失败（可能未安装），继续清理残留"
        apt-get autoremove -y --purge >/dev/null 2>&1 || true
    fi
elif is_os centos rhel rocky alma ol amazon fedora; then
    if command -v dnf >/dev/null 2>&1; then PM="dnf"; else PM="yum"; fi
    log_info "${PM} remove Docker 相关包…"
    # shellcheck disable=SC2086
    ${PM} remove -y ${DOCKER_PKGS} >/dev/null 2>&1 \
        || log_warn "部分包移除失败（可能未安装），继续清理残留"
elif is_os alpine; then
    log_info "apk del Docker 相关包…"
    # shellcheck disable=SC2086
    apk del docker docker-cli containerd docker-compose >/dev/null 2>&1 \
        || log_warn "部分包移除失败（可能未安装），继续清理残留"
else
    log_warn "未识别的发行版（${OS_NAME:-unknown}），跳过包管理器卸载，仅清理文件"
fi

# ── 清理配置与残留文件 ─────────────────────────────────────
for F in /etc/docker/daemon.json /etc/docker/key.json /var/run/docker.sock /run/docker.sock; do
    if [ -e "${F}" ]; then
        rm -f "${F}"
        log_info "已删除：${F}"
    fi
done
# 目录仅在为空时才删，避免误删用户数据
if [ -d /etc/docker ] && [ -z "$(ls -A /etc/docker 2>/dev/null)" ]; then
    rmdir /etc/docker
    log_info "已删除空目录：/etc/docker"
fi

# ── 数据目录（默认保留，需显式勾选 PURGE_DATA）─────────────
if [ "${PURGE_DATA}" = "true" ]; then
    for D in /var/lib/docker /var/lib/containerd; do
        if [ -e "${D}" ]; then
            rm -rf "${D}"
            log_warn "已删除：${D}（镜像 / 容器 / 数据卷不可恢复）"
        fi
    done
else
    if [ -d /var/lib/docker ]; then
        log_info "按要求保留 /var/lib/docker（镜像与容器数据仍在）"
    fi
    if [ -d /var/lib/containerd ]; then
        log_info "按要求保留 /var/lib/containerd"
    fi
fi

# ── 清理安装期遗留的 zapbak（已在上一步归档到 /root/zap_bak/docker/）──
for F in /etc/docker/daemon.json.zapbak.*; do
    if [ -e "${F}" ]; then
        rm -f "${F}"
    fi
done

# ── 校验结果 ───────────────────────────────────────────────
if command -v docker >/dev/null 2>&1; then
    log_warn "docker 命令仍存在：$(command -v docker)（可能由系统其它源安装，非本次安装产物）"
else
    log_ok "Docker 已卸载"
fi
