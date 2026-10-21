"""Static global-access scanner for Lua 5.1 chunks.

Compiles a source file with the real Lua 5.1 compiler (lupa), dumps the bytecode with
string.dump and walks every function prototype collecting GETGLOBAL / SETGLOBAL
instructions (plus the first constant field index right after a GETGLOBAL, so
`C_Spell.GetSpellName` is reported as such).

Used by run.py for the "static globals" section of the report, and runnable alone:

    tools\\.venv\\Scripts\\python.exe tools\\harness\\luabc.py Greenfields\\Core\\Init.lua
"""
import struct
import sys

OP_GETGLOBAL = 5
OP_SETGLOBAL = 7
OP_GETTABLE = 6
OP_SELF = 11


class _Reader:
    def __init__(self, data):
        self.d = data
        self.p = 0
        self.int_size = 4
        self.size_t = 8
        self.num_size = 8

    def byte(self):
        v = self.d[self.p]
        self.p += 1
        return v

    def int(self):
        v = int.from_bytes(self.d[self.p:self.p + self.int_size], "little", signed=True)
        self.p += self.int_size
        return v

    def sizet(self):
        v = int.from_bytes(self.d[self.p:self.p + self.size_t], "little", signed=False)
        self.p += self.size_t
        return v

    def string(self):
        n = self.sizet()
        if n == 0:
            return None
        s = self.d[self.p:self.p + n - 1]
        self.p += n
        return s.decode("utf-8", errors="replace")

    def number(self):
        v = struct.unpack("<d", self.d[self.p:self.p + 8])[0]
        self.p += 8
        return v


def _function(r, out, parent_src):
    src = r.string() or parent_src
    r.int()  # linedefined
    r.int()  # lastlinedefined
    r.byte(); r.byte(); r.byte(); r.byte()  # nups numparams vararg maxstack
    ncode = r.int()
    code = [int.from_bytes(r.d[r.p + 4 * i:r.p + 4 * i + 4], "little") for i in range(ncode)]
    r.p += 4 * ncode
    nk = r.int()
    consts = []
    for _ in range(nk):
        t = r.byte()
        if t == 0:
            consts.append(None)
        elif t == 1:
            consts.append(bool(r.byte()))
        elif t == 3:
            consts.append(r.number())
        elif t == 4:
            consts.append(r.string())
        else:
            raise ValueError("bad constant type %d" % t)
    nprotos = r.int()
    protos_start = r.p
    # protos come before debug info; recurse
    for _ in range(nprotos):
        _function(r, out, src)
    nline = r.int()
    lines = [int.from_bytes(r.d[r.p + 4 * i:r.p + 4 * i + 4], "little", signed=True) for i in range(nline)]
    r.p += 4 * nline
    nloc = r.int()
    for _ in range(nloc):
        r.string(); r.int(); r.int()
    nup = r.int()
    for _ in range(nup):
        r.string()
    del protos_start
    for pc, ins in enumerate(code):
        op = ins & 0x3F
        a = (ins >> 6) & 0xFF
        bx = ins >> 14
        line = lines[pc] if pc < len(lines) else 0
        if op in (OP_GETGLOBAL, OP_SETGLOBAL):
            name = consts[bx] if bx < len(consts) else None
            if not isinstance(name, str):
                continue
            field = None
            if op == OP_GETGLOBAL and pc + 1 < len(code):
                nxt = code[pc + 1]
                nop = nxt & 0x3F
                nb = (nxt >> 23) & 0x1FF
                nc = (nxt >> 14) & 0x1FF
                if nop in (OP_GETTABLE, OP_SELF) and nb == a and nc & 0x100:
                    k = consts[nc & 0xFF] if (nc & 0xFF) < len(consts) else None
                    if isinstance(k, str):
                        field = k
            out.append(("set" if op == OP_SETGLOBAL else "get", name, field, src, line))


def scan_bytecode(data):
    """data: bytes from string.dump -> list of (kind, name, field, source, line)."""
    r = _Reader(data)
    if data[:4] != b"\x1bLua" or data[4] != 0x51:
        raise ValueError("not a Lua 5.1 chunk")
    r.p = 6
    r.p += 1  # endianness
    r.int_size = data[7]
    r.size_t = data[8]
    r.p = 12
    out = []
    _function(r, out, "?")
    return out


def scan_sources(runtime, files):
    """files: list of (chunkname, source). Returns list of accesses; compile errors raise."""
    dump = runtime.eval("""function(src, name)
        local f, err = loadstring(src, name)
        if not f then return nil, err end
        return string.dump(f), false
    end""")
    out = []
    for name, src in files:
        if isinstance(name, str):
            name = name.encode("utf-8")
        if isinstance(src, str):
            src = src.encode("utf-8")
        data, err = dump(src, name)
        if data is None:
            raise SyntaxError(err.decode("utf-8", "replace") if isinstance(err, bytes) else err)
        if isinstance(data, str):
            data = data.encode("latin-1")
        out.extend(scan_bytecode(bytes(data)))
    return out


if __name__ == "__main__":
    import lupa.lua51 as lua51
    rt = lua51.LuaRuntime(unpack_returned_tuples=True, encoding=None)
    files = []
    for p in sys.argv[1:]:
        files.append(("@" + p, open(p, "rb").read()))
    seen = {}
    for kind, name, field, src, line in scan_sources(rt, files):
        key = (kind, name + ("." + field if field else ""))
        seen.setdefault(key, []).append("%s:%d" % (src, line))
    for (kind, name), where in sorted(seen.items()):
        print("%-3s %-50s %4d  %s" % (kind, name, len(where), where[0]))
