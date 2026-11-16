#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""FDT (Flattened Device Tree) 极简解析/原地修改工具"""
import struct, sys

FDT_MAGIC = 0xd00dfeed

class FDT:
    def __init__(self, data):
        self.d = bytearray(data)
        (self.magic, self.totalsize, self.off_struct, self.off_strings,
         self.off_rsvmap, self.version, self.last_comp, self.boot_cpuid,
         self.size_strings, self.size_struct) = struct.unpack('>10I', self.d[0:40])
        if self.magic != FDT_MAGIC:
            raise ValueError('not FDT: magic=0x%08x' % self.magic)

    def nodes(self):
        """返回 [(path, {prop: (offset, length)})]"""
        out = []
        stack = []
        off = self.off_struct
        cur = {'props': {}}
        while off < self.off_struct + self.size_struct:
            tok = struct.unpack('>I', self.d[off:off+4])[0]
            off += 4
            if tok == 1:  # FDT_BEGIN_NODE
                end = self.d.index(b'\0', off)
                name = self.d[off:end].decode('utf-8', 'replace')
                off = (end + 1 + 3) & ~3
                stack.append(name)
                cur = {'path': '/' + '/'.join(n for n in stack if n), 'props': {}}
            elif tok == 2:  # FDT_END_NODE
                out.append(cur)
                if stack: stack.pop()
            elif tok == 3:  # FDT_PROP
                ln, nameoff = struct.unpack('>II', self.d[off:off+8])
                off += 8
                send = self.d.index(b'\0', self.off_strings + nameoff)
                pname = self.d[self.off_strings+nameoff:send].decode('utf-8', 'replace')
                cur['props'][pname] = (off, ln)
                off = (off + ln + 3) & ~3
            elif tok == 4:  # FDT_NOP
                pass
            elif tok == 9:  # FDT_END
                break
            else:
                raise ValueError('bad token 0x%x at 0x%x' % (tok, off-4))
        return out

    def get(self, off, ln):
        return bytes(self.d[off:off+ln])

    def put(self, off, ln, val):
        if len(val) != ln:
            raise ValueError('length mismatch %d != %d' % (len(val), ln))
        self.d[off:off+ln] = val

    def save(self, path):
        open(path, 'wb').write(bytes(self.d))


def u32(v): return struct.pack('>I', v)
def ru32(b, i=0): return struct.unpack('>I', b[i:i+4])[0]


def dump_targets(fdt, label=''):
    """打印所有含充电关键属性的节点"""
    KEYS = ['fv', 'fv_ffc', 'battery_cv', 'iterm', 'iterm_ffc', 'iterm_ffc_warm',
            'ffc_high_soc', 'max_fcc', 'jeita_fv_cfg', 'step_chg_cfg_low_cycle',
            'step_chg_cfg_middle_cycle', 'step_chg_cfg_high_cycle',
            'report_full_rsoc_1s', 'bat-ovp-threshold', 'bat-ovp-alarm-threshold']
    print('==== %s ====' % label)
    for n in fdt.nodes():
        hits = [k for k in KEYS if k in n['props']]
        if not hits: continue
        print('  node: %s' % n['path'])
        for k in hits:
            off, ln = n['props'][k]
            b = fdt.get(off, ln)
            if ln == 4:
                print('    %-28s off=0x%06x len=%d  u32=%d (0x%x)' % (k, off, ln, ru32(b), ru32(b)))
            else:
                print('    %-28s off=0x%06x len=%d  %s' % (k, off, ln, b.hex()))


if __name__ == '__main__':
    p = sys.argv[1]
    f = FDT(open(p, 'rb').read())
    print('totalsize=%d struct@0x%x(%d) strings@0x%x(%d) ver=%d'
          % (f.totalsize, f.off_struct, f.size_struct, f.off_strings, f.size_strings, f.version))
    dump_targets(f, p)
