#!/usr/bin/env python3
"""WordPress 安装脚本（面板 provision 编排示例）。

运行身份：站点所属 Linux 账号（app.yaml: scope: site / run_as: user），
只能写自己的站点目录与家目录。面板在任务入队前已经准备好两件事
（脚本没有、也不该有对应权限）：

  1. 站点    SITE_ID / SITE_DOMAIN / SITE_ROOT / SITE_OWNER / SITE_LINUX_USER / PHP_FPM_SOCK
  2. 数据库  DB_NAME / DB_USER / DB_PASS / DB_HOST / DB_PORT / DB_CHARSET

所以本脚本只做「下载 → 解压 → 落到 $SITE_ROOT → 生成 wp-config.php → 登记 info.yaml」。
数据库密码只从环境变量读取、写进 wp-config.php（0640），不进 info.yaml、不进日志。
"""

import os
import re
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.environ["ZAP_PY_LIB"])
from zapweb import *  # noqa: E402  （log_* / env / download / extract / render / write_info …）

# WordPress 核心的 8 个密钥 / 盐值：每个实例随机生成，绝不复用
SALTS = (
    "AUTH_KEY",
    "SECURE_AUTH_KEY",
    "LOGGED_IN_KEY",
    "NONCE_KEY",
    "AUTH_SALT",
    "SECURE_AUTH_SALT",
    "LOGGED_IN_SALT",
    "NONCE_SALT",
)


def archive_url(version: str, locale: str) -> str:
    """官方下载地址；中文包走 cn.wordpress.org。"""
    if locale == "zh_CN":
        return f"https://cn.wordpress.org/wordpress-{version}-zh_CN.tar.gz"
    return f"https://wordpress.org/wordpress-{version}.tar.gz"


def move_into(src, dest, skip=()):
    """把 src 下的内容搬进 dest（已存在的同名项先删），skip 里的名字保持原样。

    dest 必须在调用前通过路径围栏（见 assert_under）。
    """
    ensure_dir(dest)
    for item in Path(src).iterdir():
        if item.name in skip:
            log_info("保留：", item.name)
            continue
        target = Path(dest) / item.name
        if target.exists() or target.is_symlink():
            if target.is_dir() and not target.is_symlink():
                shutil.rmtree(target)
            else:
                target.unlink()
        shutil.move(str(item), str(target))


def run_masked(cmd, cwd=None, check: bool = True) -> bool:
    """执行可能含密码的命令：日志里把密码打码，ps / 日志都不留明文。

    check=False 时失败只告警（用于「能自动完成最好，失败也不算安装失败」的步骤）。
    """
    safe = []
    for a in cmd:
        for flag in ("--admin_password=", "--password="):
            if a.startswith(flag):
                a = flag + mask(a[len(flag) :])
                break
        safe.append(a)
    log_info("$", " ".join(safe))
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if p.returncode != 0:
        if check:
            die(f"命令失败 ({p.returncode}): {' '.join(safe)}\n{p.stderr.strip()}")
        log_warn(f"命令失败 ({p.returncode})，已跳过：{' '.join(safe)}\n{p.stderr.strip()}")
        return False
    return True


def main():
    version = env_required("APP_VERSION")
    domain = env_required("SITE_DOMAIN")
    site_root = env_required("SITE_ROOT")
    # 路径围栏：部署目标只能是面板给出的站点根目录（防止选项值把文件带出去）
    root = assert_under(site_root, site_root)
    app_path = env_required("APP_PATH")
    locale = env("LOCALE", "zh_CN")
    prefix = env("TABLE_PREFIX", "wp_")
    site_url = f"http://{domain}"

    # 选项值一律当「不可信输入」对待：表前缀进 PHP 单引号串，域名进 URL
    if not re.fullmatch(r"[A-Za-z0-9_]+", prefix):
        die(f"非法的表前缀: {prefix}（只允许字母 / 数字 / 下划线）")
    if not re.fullmatch(r"[A-Za-z0-9.-]+", domain):
        die(f"非法的站点域名: {domain}")

    log_info(f"安装 WordPress {version}（{locale}）→ {root}，站点 {site_url}")
    if (root / "wp-settings.php").is_file():
        die("站点根目录已存在 WordPress，请改用「升级」而不是重复安装")

    # ── 下载 → 解压 → 落到站点根目录 ────────────────────────────
    tmp = tmp_dir("wordpress-")
    archive = download(archive_url(version, locale), Path(tmp) / f"wordpress-{version}.tar.gz")
    src = single_subdir(extract(archive, Path(tmp) / "src"))
    if not (src / "wp-settings.php").is_file():
        die("解压结果不是 WordPress 程序包")
    move_into(src, root)
    log_ok("程序已部署：", root)

    # ── 权限：目录 755 / 文件 644，上传目录要能写 ────────────────
    # 顺序有讲究：chmod_tree 会把目录下所有文件统一刷成 644，
    # 而 wp-config.php 里是数据库明文密码，必须保持 render() 给的 0640，
    # 所以它只能在 chmod_tree 之后生成。
    chmod_tree(root)
    ensure_dir(root / "wp-content" / "uploads")
    log_ok("权限已规整：", root)

    # ── 生成 wp-config.php ─────────────────────────────────────
    db_host = env("DB_HOST", "127.0.0.1")
    port = env("DB_PORT", "3306")
    mapping = {
        "GENERATED_AT": time.strftime("%Y-%m-%d %H:%M:%S"),
        "DB_NAME": env_required("DB_NAME"),
        "DB_USER": env_required("DB_USER"),
        "DB_PASSWORD": env_required("DB_PASS"),
        "DB_HOST": f"{db_host}:{port}" if port else db_host,
        "DB_CHARSET": env("DB_CHARSET", "utf8mb4"),
        "DB_COLLATE": "",
        "TABLE_PREFIX": prefix,
        "WP_HOME": site_url,
        "WP_SITEURL": site_url,
    }
    for key in SALTS:
        mapping[key] = random_password(64)
    config = root / "wp-config.php"
    render(
        Path(env_required("PKG_SRC_PATH")) / "wp-config.php.tpl",
        config,
        mapping,
    )
    try:
        config.chmod(0o640)  # 保险：即便以后调整了调用顺序，密码也不外泄
    except OSError:
        pass

    # ── 初始化站点（装了 WP-CLI 就自动建管理员，否则交给浏览器）──
    # wp 由应用商店「应用」分类里的 WP-CLI 包提供（/usr/local/bin/wp），
    # 这里只使用、不下载 —— 站点脚本不该在安装过程中往系统里装东西。
    admin = env("ADMIN_USER")
    wp = shutil.which("wp")
    if wp and admin:
        # 失败不算安装失败：程序与配置已就位，用户可走浏览器向导
        if run_masked(
            [
                wp,
                "core",
                "install",
                f"--url={site_url}",
                f"--title={env('SITE_TITLE', '我的站点')}",
                f"--admin_user={admin}",
                f"--admin_email={env_required('ADMIN_EMAIL')}",
                f"--admin_password={env_required('ADMIN_PASSWORD')}",
                "--skip-email",
            ],
            cwd=str(root),
            check=False,
        ):
            log_ok("已完成 WordPress 初始化：", site_url)
        else:
            log_warn("自动初始化未完成，访问 %s 走安装向导（数据库信息已写入 wp-config.php）" % site_url)
    else:
        log_warn("未找到 wp 命令（应用商店 → 应用 → WP-CLI），程序文件已就位：访问 %s 完成安装向导（数据库信息已写入 wp-config.php）" % site_url)

    # ── 登记实例信息（密码类字段一律不写）───────────────────────
    write_info(
        app_path,
        instance="wordpress",
        version=version,
        locale=locale,
        domain=domain,
        site_id=env("SITE_ID"),
        site_root=str(root),
        site_url=site_url,
        db_name=mapping["DB_NAME"],
        db_user=mapping["DB_USER"],
        table_prefix=prefix,
        admin_user=admin,
        config_file=str(config),
    )

    log_ok(f"WordPress {version} installing successful")
    log_info("站点：%s（库 %s，账号 %s，密码见 wp-config.php）" % (site_url, mapping["DB_NAME"], mapping["DB_USER"]))


if __name__ == "__main__":
    main()
