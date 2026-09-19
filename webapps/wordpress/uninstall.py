#!/usr/bin/env python3
"""WordPress 卸载脚本。

运行身份与安装一致（站点 Linux 账号），因此：
- 站点根目录由面板给出（SITE_ROOT），只删 WordPress 自己的文件，绝不删根目录本身；
- 数据库信息由面板回传（DB_*）：先用 mysqldump 备份（默认开），再决定是否 DROP；
  凭据走临时 defaults 文件（0600），不出现在命令行 / 日志里；
- 备份落在站点账号家目录的 backups/，zapexec 结束时会清掉 APP_PATH，家目录不受影响。

默认**不删数据库**：文章、设置、上传都是用户数据，删库要显式勾 DROP_DB。
"""

import os
import shutil
import sys
import time

sys.path.insert(0, os.environ["ZAP_PY_LIB"])
from zapweb import *  # noqa: E402

# WordPress 核心占用的顶层路径（逐个删除，不整目录 rm -rf 站点根）
CORE_PATHS = (
    "wp-admin",
    "wp-includes",
    "wp-activate.php",
    "wp-blog-header.php",
    "wp-comments-post.php",
    "wp-config-sample.php",
    "wp-cron.php",
    "wp-links-opml.php",
    "wp-load.php",
    "wp-login.php",
    "wp-mail.php",
    "wp-settings.php",
    "wp-signup.php",
    "wp-trackback.php",
    "xmlrpc.php",
    "index.php",
    "license.txt",
    "readme.html",
)


def truthy(value: str) -> bool:
    """表单里的 bool 选项被序列化为 'true' / 'false'。"""
    return value.strip().lower() in ("1", "true", "yes", "y", "on")


def mysql_defaults_file():
    """写一份 0600 的客户端凭据文件：避免密码出现在 ps / 日志中。"""
    path = Path(tmp_dir("wp-my-")) / "client.cnf"
    path.write_text(
        "\n".join(
            [
                "[client]",
                f"host={env('DB_HOST', '127.0.0.1')}",
                f"port={env('DB_PORT', '3306')}",
                f"user={env_required('DB_USER')}",
                f"password={env_required('DB_PASS')}",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    path.chmod(0o600)
    return path


def backup_db(db: str):
    """mysqldump 到 ~/backups/；失败不阻断卸载（数据比流程重要）。"""
    dest = home() / "backups"
    ensure_dir(dest)
    sql = dest / f"{env('SITE_DOMAIN', 'wordpress')}-{time.strftime('%Y%m%d-%H%M%S')}.sql"
    cnf = mysql_defaults_file()
    try:
        run(["mysqldump", f"--defaults-extra-file={cnf}", "--single-transaction", "--quick", db, f"--result-file={sql}"])
        log_ok("数据库已备份：", sql)
    except SystemExit:
        log_warn("数据库备份失败（继续卸载，文件不会被删除以外的操作影响）")
    finally:
        cnf.unlink(missing_ok=True)


def main():
    site_root = env_required("SITE_ROOT")
    # 围栏：只在这个站点根目录内部删除，绝不触碰根目录本身
    root = assert_under(site_root, site_root)
    db = env("DB_NAME")
    has_db = bool(db and env("DB_USER") and env("DB_PASS"))

    log_info("准备卸载 WordPress（站点根目录 %s）" % root)
    if not (root / "wp-settings.php").is_file():
        log_warn("站点根目录下没有 WordPress，仅清理残留文件")

    # ── 1. 备份数据库（默认开）──────────────────────────────────
    if has_db and truthy(env("BACKUP_DB", "true")):
        backup_db(db)
    elif not has_db:
        log_warn("未拿到数据库信息（provision 缺失），跳过备份与删库")

    # ── 2. 删除程序文件 ─────────────────────────────────────────
    removed = []
    names = list(CORE_PATHS)
    names += ["wp-config.php"]
    if truthy(env("REMOVE_CONTENT", "true")):
        names.append("wp-content")
    for name in names:
        target = assert_under(root / name, root)
        if not (target.exists() or target.is_symlink()):
            continue
        if target.is_dir() and not target.is_symlink():
            shutil.rmtree(target)
        else:
            target.unlink()
        removed.append(name)
    log_ok("已删除 %d 项：%s" % (len(removed), ", ".join(removed) or "（无）"))

    # ── 3. 可选删库（默认关）────────────────────────────────────
    if has_db and truthy(env("DROP_DB", "false")):
        cnf = mysql_defaults_file()
        try:
            run(["mysql", f"--defaults-extra-file={cnf}", "-e", f"DROP DATABASE `{db}`"])
            log_warn("已删除数据库：", db)
        except SystemExit:
            log_error("删除数据库失败（已保留）：", db)
        finally:
            cnf.unlink(missing_ok=True)
    elif has_db:
        log_info("保留数据库 %s（需要清理请在「数据库」里操作）" % db)

    log_ok("WordPress uninstalling successful")


if __name__ == "__main__":
    main()
