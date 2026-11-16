#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Package a KernelSU/Magisk module directory into a flashable zip.

Generic on purpose: only the required-file list is vcut-specific, everything
else is driven by arguments, so the same script can pack any module tree.

Usage:
    python pack_module.py                                   # 打包 vcut 默认路径
    python pack_module.py --src <dir> --out <zip>
    python pack_module.py --src <dir> --out <zip> --check-version 20080
    python pack_module.py --dry-run                          # 只列清单不打包

Automatically excluded (build leftovers, never shipped):
    *.o  *.mod.o  *.mod.c  *.pyc  __pycache__  *.bak*  *.md  dotfiles
"""
import argparse
import hashlib
import os
import re
import sys
import zipfile

PROJ = os.environ.get("VCUT_PROJ", r"<repo>")

DEFAULT_SRC = PROJ + "/xaga_vcut_module"
DEFAULT_OUT = PROJ + "/xaga_vcut_release.zip"

# 模块必须包含的文件（缺一个就拒绝打包）
REQUIRED = [
    "module.prop",
    "service.sh",
    "action.sh",
    "uninstall.sh",
    "customize.sh",
    "config.sh.default",
    "vcut_turbo.sh",
    "collect.sh",
    "vcut_lower.ko",
    "vcutlower.apk",
    "META-INF/com/google/android/update-binary",
    "META-INF/com/google/android/updater-script",
]

EXCLUDED_EXT = (".o", ".mod.o", ".mod.c", ".pyc", ".md")
EXCLUDED_DIRS = {"__pycache__"}


def is_excluded(name):
    if name.endswith(EXCLUDED_EXT):
        return True
    if ".bak" in name or name.startswith("."):
        return True
    return False


def read_version(src):
    text = open(os.path.join(src, "module.prop"), encoding="utf-8").read()
    ver = re.search(r"^version=(.*)$", text, re.M)
    code = re.search(r"^versionCode=(\d+)$", text, re.M)
    return (ver.group(1).strip() if ver else "?"), (int(code.group(1)) if code else 0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=DEFAULT_SRC)
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--check-version", type=int, default=0,
                    help="要求 module.prop 的 versionCode 等于该值，否则中止")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    src = os.path.abspath(args.src)
    out = os.path.abspath(args.out)
    if not os.path.isdir(src):
        sys.exit("ERROR: 模块目录不存在: " + src)

    version, code = read_version(src)
    if args.check_version and code != args.check_version:
        sys.exit("ERROR: versionCode=%d，期望 %d" % (code, args.check_version))

    files = []
    for root, dirs, names in os.walk(src):
        dirs[:] = [d for d in dirs if d not in EXCLUDED_DIRS]
        for n in names:
            if is_excluded(n):
                continue
            full = os.path.join(root, n)
            rel = os.path.relpath(full, src).replace("\\", "/")
            files.append((rel, full))
    files.sort(key=lambda x: x[0])

    # 脚本/配置必须是 LF：/system/bin/sh 遇到 CRLF 会报 syntax error、
    # 变量值尾部带回车会让路径失效，开机时 service.sh 直接静默失败。
    # 2026-11-06 踩过：Python 在 Windows 改写文件默认写出 CRLF，打包后
    # 模块整个不加载。这里在打包前拦住，避免再流出坏包。
    bad = []
    for rel, full in files:
        if rel.endswith((".sh", ".default", ".prop")) or rel.endswith("update-binary"):
            with open(full, "rb") as f:
                if bytes([13]) in f.read():
                    bad.append(rel)
    if bad:
        print("ERROR: 以下文件含 CR（CRLF），/system/bin/sh 会解析失败:")
        for b_ in bad:
            print("  " + b_)
        print("请先用 dos2unix 或 python 转成 LF 再打包")
        sys.exit(1)

    have = {r for r, _ in files}
    missing = [r for r in REQUIRED if r not in have]
    if missing:
        print("ERROR: 缺少文件:")
        for m in missing:
            print("  " + m)
        sys.exit(1)

    print("模块: %s" % src)
    print("版本: %s  (versionCode %d)" % (version, code))
    print("输出: %s" % out)
    print("文件: %d 个" % len(files))
    if args.dry_run:
        for rel, full in files:
            print("  %9d  %s" % (os.path.getsize(full), rel))
        return

    if os.path.exists(out):
        os.remove(out)

    raw = 0
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for rel, full in files:
            raw += os.path.getsize(full)
            if rel.endswith(".sh") or rel.endswith("update-binary"):
                info = zipfile.ZipInfo(rel)
                info.external_attr = (0o755 << 16) | 0o200000000
                info.compress_type = zipfile.ZIP_DEFLATED
                with open(full, "rb") as f:
                    z.writestr(info, f.read())
            else:
                z.write(full, rel)

    size = os.path.getsize(out)
    sha = hashlib.sha256(open(out, "rb").read()).hexdigest()
    print("原始: %d B   压缩: %d B" % (raw, size))
    print("SHA-256: " + sha)
    print("\n包内清单:")
    with zipfile.ZipFile(out) as z:
        for i in z.infolist():
            print("  %9d  %s" % (i.file_size, i.filename))


if __name__ == "__main__":
    main()
