#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Build an out-of-tree ARM64 kernel module for the Xiaomi MT6895 (xaga) device
without running the kernel kbuild system.

Steps:
  1. compile <src>.c -> <src>.o   (clang, device-accurate autoconf.h)
  2. collect undefined symbols from <src>.o
  3. look up CRCs in the vendor __versions tables
  4. generate <src>.mod.c containing __versions[] + vermagic
  5. compile + link both objects into <name>.ko

Usage: python build_ko.py <src.c> <output.ko> [modname]
"""
import os
import re
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

PROJ = os.environ.get("VCUT_PROJ", r"<repo>")
KSRC = os.environ.get("VCUT_KSRC", PROJ + "/kernel_src")
TOOLS = os.environ.get("DSH_TOOLS", r"$DSH_TOOLS")
NDK = os.environ.get(
    "VCUT_NDK",
    TOOLS + "/ndk-r23c/toolchains/llvm/prebuilt/windows-x86_64/bin",
)
CLANG = NDK + "/clang.exe"
LDLLD = NDK + "/ld.lld.exe"
NM = NDK + "/llvm-nm.exe"
READELF = NDK + "/llvm-readelf.exe"

# 厂商 ko 目录：从里面的 __versions 段提取符号 CRC
VENDOR_KO_DIRS = [
    d for d in os.environ.get("VCUT_VENDOR_KO", "").split(os.pathsep) if d
] or [
    PROJ + "/devdump/ko",
    PROJ + "/vcut_ref",
]

VERMAGIC = "5.10.237-Fuutao-Qn_miao-gc5e20589c SMP preempt mod_unload modversions aarch64"

# Symbols whose CRC must NOT be taken from a foreign kernel build. The only
# __versions table containing them comes from vcut_lower.ko (kernel 6.12);
# using that CRC makes the 5.10 kernel reject the module with
# "disagrees about version of symbol". Omitting the entry makes the kernel
# fall back to a warning ("no symbol version for X") and load anyway.
CRC_BLACKLIST = {
    "register_kprobe",
    "unregister_kprobe",
    "register_kretprobe",
    "unregister_kretprobe",
    "kallsyms_lookup_name",
}


def run(cmd, **kw):
    p = subprocess.run(cmd, capture_output=True, **kw)
    def dec(b):
        if b is None:
            return ""
        return b.decode("utf-8", "replace")
    return p.returncode, dec(p.stdout), dec(p.stderr)


def parse_versions(ko_path):
    """Return {symbol: crc} from the __versions section of an ELF64 .ko."""
    rc, out, _ = run([READELF, "-S", "-W", ko_path])
    if rc != 0:
        return {}
    sec = None
    for line in out.splitlines():
        # [Nr] Name Type Address Off Size ES Flg Lk Inf Al
        m = re.match(r"\s*\[\s*\d+\]\s+(\S+)\s+(\S+)\s+([0-9a-f]+)\s+([0-9a-f]+)\s+([0-9a-f]+)", line)
        if m and m.group(1) == "__versions":
            sec = (int(m.group(4), 16), int(m.group(5), 16))
            break
    if not sec:
        return {}
    off, size = sec
    with open(ko_path, "rb") as f:
        f.seek(off)
        data = f.read(size)
    res = {}
    # struct modversion_info { unsigned long crc; char name[MODULE_NAME_LEN]; }
    # MODULE_NAME_LEN = 56 on this kernel -> entry = 8 + 56 = 64 bytes
    for i in range(0, len(data) - 63, 64):
        crc = struct.unpack_from("<Q", data, i)[0]
        name = data[i + 8:i + 64].split(b"\x00")[0].decode("ascii", "replace")
        if name:
            res[name] = crc & 0xFFFFFFFF
    return res


def collect_crcs():
    all_crcs = {}
    for d in VENDOR_KO_DIRS:
        if not os.path.isdir(d):
            continue
        for f in sorted(os.listdir(d)):
            if not f.endswith(".ko"):
                continue
            p = os.path.join(d, f)
            try:
                c = parse_versions(p)
            except Exception:
                continue
            for k, v in c.items():
                all_crcs.setdefault(k, v)
    return all_crcs


def cflags(modname):
    res = run([CLANG, "-print-resource-dir"])[1].strip()
    return [
        "--target=aarch64-linux-android21",
        "-D__KERNEL__", "-DMODULE",
        '-DKBUILD_MODNAME="%s"' % modname,
        "-DINCLUDE_VERMAGIC",
        # CFI (CONFIG_CFI_CLANG=y) requires LTO + hidden visibility
        "-flto",
        "-fvisibility=hidden",
        "-fsanitize=cfi",
        "-fsanitize-cfi-cross-dso",
        "-fno-sanitize-cfi-canonical-jump-tables",
        "-fno-sanitize-blacklist",
        # CONFIG_CFI_PERMISSIVE is not set AND CONFIG_UBSAN_TRAP=y
        # -> kernel Makefile does NOT add -ftrap-function; default brk #0x5502
        #    is used, which matches the vendor modules (self-contained trap).
        "-fno-sanitize-trap=undefined",
        "-nostdinc",
        "-isystem", res + "/include",
        "-isystem", NDK + "/../sysroot/usr/include",
        "-I" + KSRC + "/arch/arm64/include",
        "-I" + KSRC + "/arch/arm64/include/generated",
        "-I" + KSRC + "/include",
        "-I" + KSRC + "/include/generated",
        "-I" + KSRC + "/arch/arm64/include/uapi",
        "-I" + KSRC + "/include/uapi",
        "-include", KSRC + "/include/generated/autoconf.h",
        "-fno-strict-aliasing", "-fno-common", "-fshort-wchar", "-fno-PIE",
        "-mno-outline-atomics", "-mgeneral-regs-only",
        # CONFIG_ARM64_PTR_AUTH=y + CONFIG_ARM64_BTI_KERNEL=y
        "-mbranch-protection=pac-ret+leaf+bti",
        # CONFIG_SHADOW_CALL_STACK=y
        "-fsanitize=shadow-call-stack",
        "-fno-asynchronous-unwind-tables",
        "-fno-delete-null-pointer-checks",
        "-O2", "-c",
    ]


def undefined_symbols(obj):
    rc, out, err = run([NM, "-u", obj])
    syms = []
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) >= 2 and parts[0] == "U":
            syms.append(parts[1])
    return syms


def gen_mod_c(modname, crcs):
    """Generate <modname>.mod.c with __versions, __this_module and vermagic."""
    lines = []
    lines.append('#include <linux/module.h>')
    lines.append('#include <linux/vermagic.h>')
    lines.append('#include <linux/compiler.h>')
    lines.append('')
    lines.append('#ifndef MODULE_ARCH_INIT')
    lines.append('#define MODULE_ARCH_INIT {}')
    lines.append('#endif')
    lines.append('')
    # __this_module is mandatory: the loader binds it to struct module
    lines.append('extern struct module __this_module;')
    lines.append('struct module __this_module')
    lines.append('__used __section(".gnu.linkonce.this_module") = {')
    lines.append('\t.name = KBUILD_MODNAME,')
    lines.append('\t.init = init_module,')
    lines.append('#ifdef CONFIG_MODULE_UNLOAD')
    lines.append('\t.exit = cleanup_module,')
    lines.append('#endif')
    lines.append('\t.arch = MODULE_ARCH_INIT,')
    lines.append('};')
    lines.append('')
    lines.append('static const struct modversion_info ____versions[]')
    lines.append('__used __section("__versions") = {')
    for name in sorted(crcs):
        lines.append('\t{ 0x%08x, "%s" },' % (crcs[name], name))
    lines.append('};')
    lines.append('')
    lines.append('static const char __module_vermagic[]')
    lines.append('__used __section(".modinfo") =')
    lines.append('\t"vermagic=" VERMAGIC_STRING;')
    lines.append('')
    lines.append('MODULE_INFO(name, KBUILD_MODNAME);')
    lines.append('MODULE_LICENSE("GPL v2");')
    lines.append('')
    return "\n".join(lines) + "\n"


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    src = os.path.abspath(sys.argv[1])
    out = os.path.abspath(sys.argv[2])
    modname = sys.argv[3] if len(sys.argv) > 3 else os.path.splitext(os.path.basename(out))[0]

    work = os.path.dirname(out)
    base = os.path.splitext(os.path.basename(src))[0]
    obj = os.path.join(work, base + ".o")
    modc = os.path.join(work, base + ".mod.c")
    modobj = os.path.join(work, base + ".mod.o")

    cf = cflags(modname)

    print("[1/5] compiling %s" % os.path.basename(src))
    rc, o, e = run([CLANG] + cf + [src, "-o", obj])
    if rc != 0:
        print(e[:4000])
        return 1
    print("      ok (%d bytes)" % os.path.getsize(obj))

    print("[2/5] collecting undefined symbols")
    undef = undefined_symbols(obj)
    print("      %d symbols: %s" % (len(undef), ", ".join(undef[:8]) + ("..." if len(undef) > 8 else "")))

    print("[3/5] looking up CRCs in vendor __versions tables")
    all_crcs = collect_crcs()
    found, missing = {}, []
    for s in undef:
        if s in CRC_BLACKLIST:
            missing.append(s)
        elif s in all_crcs:
            found[s] = all_crcs[s]
        else:
            missing.append(s)
    print("      found %d, missing %d" % (len(found), len(missing)))
    if missing:
        # Do NOT emit a __versions entry with a bogus CRC: the kernel then
        # reports "disagrees about version of symbol" and refuses to load.
        # A missing entry only triggers "no symbol version for X" (warning).
        print("      omitted (no CRC): %s" % ", ".join(missing))
    # always include module_layout
    if "module_layout" in all_crcs:
        found["module_layout"] = all_crcs["module_layout"]

    print("[4/5] generating %s" % os.path.basename(modc))
    with open(modc, "w", encoding="utf-8") as f:
        f.write(gen_mod_c(modname, found))
    rc, o, e = run([CLANG] + cf + [modc, "-o", modobj])
    if rc != 0:
        print(e[:4000])
        return 1
    print("      ok")

    print("[5/5] linking %s" % os.path.basename(out))
    lds = os.path.join(HERE, "module.lds")
    rc, o, e = run([LDLLD, "-r", "-o", out, "-T", lds, obj, modobj])
    if rc != 0:
        print(e[:2000])
        return 1
    print("      ok (%d bytes)" % os.path.getsize(out))
    print("\nBUILD OK -> %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
