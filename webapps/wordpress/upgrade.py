#!/usr/bin/env python3
"""WordPress 升级脚本：只换核心文件。

保留 wp-content（主题 / 插件 / 上传）与 wp-config.php（面板建的库连接信息），
覆盖 wp-admin / wp-includes 与根目录的 wp-*.php；有 wp-cli 时顺带 `wp core update-db`。

升级复用安装时的 provision（同一个站点、同一个库），不会重建数据库。
"""

import os
import shutil
import sys
import time

sys.path.insert(0, os.environ["ZAP_PY_LIB"])
from zapweb import *  # noqa: E402

# 升级时必须原样保留的内容
KEEP = ("wp-content", "wp-config.php")


def move_into(src, dest, skip=()):
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


def main():
    import yaml  # 仅升级需要读回旧的 info.yaml

    version = env_required("APP_VERSION")
    site_root = env_required("SITE_ROOT")
    root = assert_under(site_root, site_root)
    app_path = Path(env_required("APP_PATH"))

    if not (root / "wp-settings.php").is_file():
        die("站点根目录下没有 WordPress，请先安装再升级")
    log_info("升级 WordPress 到 %s（保留 wp-content 与 wp-config.php）" % version)

    # wp-config.php 不在核心包里，但保留一份以防万一
    cfg = root / "wp-config.php"
    bak = None
    if cfg.is_file():
        bak = cfg.with_name(f"wp-config.php.bak.{int(time.time())}")
        shutil.copy2(cfg, bak)

    tmp = tmp_dir("wordpress-up-")
    archive = download(
        f"https://wordpress.org/wordpress-{version}.tar.gz",
        Path(tmp) / f"wordpress-{version}.tar.gz",
    )
    src = single_subdir(extract(archive, Path(tmp) / "src"))
    if not (src / "wp-settings.php").is_file():
        die("解压结果不是 WordPress 程序包")
    move_into(src, root, skip=KEEP)

    if bak is not None and not cfg.is_file():
        shutil.move(str(bak), str(cfg))
        bak = None
    if bak is not None:
        bak.unlink(missing_ok=True)

    chmod_tree(root)
    if cfg.is_file():
        cfg.chmod(0o640)  # 配置里含数据库密码
    log_ok("核心文件已替换：", root)

    wp = shutil.which("wp")
    if wp:
        run([wp, "core", "update-db"], cwd=str(root))
        log_ok("数据库结构已更新")
    else:
        log_warn("未找到 wp-cli：请登录后台，按提示点击「更新 WordPress 数据库」")

    # 更新实例登记里的版本（保留其它字段）
    info_file = app_path / "info.yaml"
    data = yaml.safe_load(info_file.read_text(encoding="utf-8")) if info_file.is_file() else {}
    data = data if isinstance(data, dict) else {}
    data["version"] = version
    data["upgraded_at"] = time.strftime("%Y-%m-%d %H:%M:%S")
    write_info(app_path, **{k: str(v) for k, v in data.items() if v is not None})

    log_ok(f"WordPress {version} upgrading successful")


if __name__ == "__main__":
    main()
