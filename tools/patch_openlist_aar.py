"""Patch OpenList AAR so its gomobile runtime can coexist with libXray.

Background (this is the third iteration and the previous two were wrong):

  * The kernel .so exports JNI symbols `Java_go_Seq_*`, `Java_go_Universe_*`
    and `Java_openlistcore_Openlistcore_*`. JNI resolves those by the *Java
    class name*, so the kernel's Java classes must keep the same symbol
    spelling that the .so was compiled with.
  * libXray.aar ships its own `go/Seq.class` (loading `libgojni.so`). If the
    kernel AAR also ships `go/Seq.class` the dex merge fails with duplicate
    classes; if we drop the kernel's copy, then the only `go.Seq` in the APK
    loads `libgojni.so`, and `Java_openlistcore_*` can never be resolved --
    every kernel call dies with UnsatisfiedLinkError.

Fix: give the kernel its own gomobile runtime under package `gx` instead of
`go`, and patch the .so symbol names to match (`go` -> `gx`, same length, so
the ELF string table stays byte-stable). Then:

  * main process  -> go.Seq    -> libgojni.so        (libXray, unchanged)
  * :openlist     -> gx.Seq    -> libopenlistjni.so  (kernel, isolated)

The loadLibrary argument is rewritten gojni -> openlistjni as before.
"""
import io
import os
import struct
import sys
import zipfile

DEFAULT_SRC = os.path.join(os.environ.get("TEMP", "/tmp"),
                           "openlist-core", "extracted", "openlistcore.aar")
SRC = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SRC
DST = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "android", "app", "libs", "openlistcore-patched.aar")

# Same-length renames only: the .so keeps identical byte offsets.
PKG_RENAMES = [
    (b"go/Seq", b"gx/Seq"),
    (b"go/Universe", b"gx/Universe"),
    (b"go/error", b"gx/error"),
    (b"Java_go_", b"Java_gx_"),
]


def mutate_utf8(raw: bytes) -> bytes:
    out = raw
    for old, new in PKG_RENAMES:
        assert len(old) == len(new), old
        out = out.replace(old, new)
    if out == b"gojni":
        out = b"openlistjni"
    return out


def patch_class(data: bytes) -> bytes:
    """Rewrite UTF8 constants: go/* -> gx/*, gojni -> openlistjni."""
    if len(data) < 10 or data[:4] != b"\xca\xfe\xba\xbe":
        return data
    pos = 8
    count = struct.unpack_from(">H", data, pos)[0]
    pos += 2
    out = bytearray(data[:pos])
    i = 1
    changed = False
    while i < count:
        tag = data[pos]
        out.append(tag)
        pos += 1
        if tag == 1:  # CONSTANT_Utf8
            length = struct.unpack_from(">H", data, pos)[0]
            pos += 2
            raw = data[pos:pos + length]
            pos += length
            new = mutate_utf8(raw)
            changed |= new != raw
            out.extend(struct.pack(">H", len(new)))
            out.extend(new)
        elif tag in (3, 4, 9, 10, 11, 12, 17, 18):
            out.extend(data[pos:pos + 4]); pos += 4
        elif tag in (5, 6):
            out.extend(data[pos:pos + 8]); pos += 8
            i += 1
        elif tag in (7, 8, 16, 19, 20):
            out.extend(data[pos:pos + 2]); pos += 2
        elif tag == 15:
            out.extend(data[pos:pos + 3]); pos += 3
        else:
            raise ValueError(f"unknown constant tag {tag}")
        i += 1
    out.extend(data[pos:])
    return bytes(out) if changed else data


def gnu_hash(name: bytes) -> int:
    h = 5381
    for c in name:
        h = ((h * 33) + c) & 0xFFFFFFFF
    return h


def _elf_sections(data: bytes):
    is64 = data[4] == 2
    if is64:
        shoff = struct.unpack_from("<Q", data, 0x28)[0]
        shentsize = struct.unpack_from("<H", data, 0x3A)[0]
        shnum = struct.unpack_from("<H", data, 0x3C)[0]
        shstrndx = struct.unpack_from("<H", data, 0x3E)[0]
        fmt = "<IIQQQQIIQQ"
    else:
        shoff = struct.unpack_from("<I", data, 0x20)[0]
        shentsize = struct.unpack_from("<H", data, 0x2E)[0]
        shnum = struct.unpack_from("<H", data, 0x30)[0]
        shstrndx = struct.unpack_from("<H", data, 0x32)[0]
        fmt = "<IIIIIIIIII"
    keys = ["name", "type", "flags", "addr", "offset", "size", "link", "info",
            "align", "entsize"]
    secs = [dict(zip(keys, struct.unpack_from(fmt, data, shoff + i * shentsize)))
            for i in range(shnum)]
    shstr = secs[shstrndx]
    strtab = data[shstr["offset"]:shstr["offset"] + shstr["size"]]

    def sec_name(off):
        end = strtab.find(b"\0", off)
        return strtab[off:end].decode("ascii", "replace")

    return is64, secs, sec_name


def rebuild_gnu_hash(data: bytes) -> bytes:
    """Recompute .gnu.hash after symbol renames.

    dlsym resolves through the GNU hash table, not by scanning .dynsym, so a
    same-length rename leaves every renamed symbol un-findable even though the
    string table and dynsym still look correct. We rebuild bloom/buckets/chain
    in place (identical byte size) using a single chain that covers every
    hashed symbol: buckets all point at symoffset and only the last chain entry
    carries the end-of-chain bit. Correct, just O(n) per lookup (~570 syms).
    """
    is64, secs, sec_name = _elf_sections(data)
    named = {sec_name(s["name"]): s for s in secs}
    if ".gnu.hash" not in named or ".dynsym" not in named or ".dynstr" not in named:
        return data

    dynsym = named[".dynsym"]
    dstr = named[".dynstr"]
    strings = data[dstr["offset"]:dstr["offset"] + dstr["size"]]
    ent = dynsym["entsize"] or (24 if is64 else 16)
    nsyms = dynsym["size"] // ent

    names = []
    for k in range(nsyms):
        st_name = struct.unpack_from("<I", data, dynsym["offset"] + k * ent)[0]
        end = strings.find(b"\0", st_name)
        names.append(strings[st_name:end])

    g = named[".gnu.hash"]
    base = g["offset"]
    nbuckets, symoffset, bloom_size, bloom_shift = struct.unpack_from(
        "<IIII", data, base)
    word = 8 if is64 else 4
    bloom_off = base + 16
    buckets_off = bloom_off + bloom_size * word
    chain_off = buckets_off + nbuckets * 4
    chain_len = nsyms - symoffset
    limit = g["size"]
    need = 16 + bloom_size * word + nbuckets * 4 + chain_len * 4
    if need > limit:
        raise ValueError(f"gnu.hash too small: need {need}, have {limit}")

    out = bytearray(data)
    # bloom filter
    bloom = [0] * bloom_size
    hashes = []
    for idx in range(symoffset, nsyms):
        name = names[idx]
        h = gnu_hash(name) if name else 0
        hashes.append(h)
        bits = 64 if is64 else 32
        bloom[(h // bits) % bloom_size] |= (1 << (h % bits)) | \
            (1 << ((h >> bloom_shift) % bits))
    for i, v in enumerate(bloom):
        struct.pack_into("<Q" if is64 else "<I", out, bloom_off + i * word, v)
    # buckets -> every bucket points at the first hashed symbol
    for i in range(nbuckets):
        struct.pack_into("<I", out, buckets_off + i * 4, symoffset)
    # chain -> true hash of every symbol, end bit only on the last one
    for i, h in enumerate(hashes):
        struct.pack_into("<I", out, chain_off + i * 4, h & 0xFFFFFFFE)
    if chain_len:
        last = chain_off + (chain_len - 1) * 4
        struct.pack_into("<I", out, last,
                         struct.unpack_from("<I", out, last)[0] | 1)
    return bytes(out)


def patch_so(data: bytes) -> bytes:
    """Rename JNI entry points and class literals inside the ELF."""
    for old, new in PKG_RENAMES:
        assert len(old) == len(new), old
        data = data.replace(old, new)
    return rebuild_gnu_hash(data)


with zipfile.ZipFile(SRC) as zin:
    jar = zin.read("classes.jar")
    so_files = {n: zin.read(n) for n in zin.namelist() if n.endswith(".so")}
    others = {n: zin.read(n) for n in zin.namelist()
              if not n.endswith(".so") and n != "classes.jar"}

with zipfile.ZipFile(io.BytesIO(jar)) as j:
    entries = {}
    for name in j.namelist():
        raw = j.read(name)
        new_name = name
        if name.startswith("go/"):
            new_name = "gx/" + name[len("go/"):]
        entries[new_name] = patch_class(raw)

patched_jar = io.BytesIO()
with zipfile.ZipFile(patched_jar, "w", zipfile.ZIP_DEFLATED) as out:
    for name, data in entries.items():
        out.writestr(name, data)

with zipfile.ZipFile(DST, "w", zipfile.ZIP_DEFLATED) as out:
    for name, data in others.items():
        out.writestr(name, data)
    out.writestr("classes.jar", patched_jar.getvalue())
    for name, data in so_files.items():
        if "x86_64" in name:
            continue  # 只保留 arm，减体积；release 也只出 arm
        out.writestr(name.replace("libgojni.so", "libopenlistjni.so"),
                     patch_so(data))

print("patched:", DST, os.path.getsize(DST))

# ---- verification ----
with zipfile.ZipFile(DST) as z:
    print("so entries:", [n for n in z.namelist() if n.endswith(".so")])
    with zipfile.ZipFile(io.BytesIO(z.read("classes.jar"))) as j:
        names = j.namelist()
        print("classes:", sorted(n for n in names if n.endswith(".class")))
        bad = []
        for n in names:
            if not n.endswith(".class"):
                continue
            d = j.read(n)
            if b"go/Seq" in d or b"go/Universe" in d or b"gojni" in d:
                bad.append(n)
        print("classes still referencing go/* or gojni:", bad)
        seq = j.read("gx/Seq.class")
        print("gx/Seq loads openlistjni:", b"openlistjni" in seq)
        core = j.read("openlistcore/Openlistcore.class")
        print("Openlistcore references gx/Seq:", b"gx/Seq" in core)
    so = z.read("jni/arm64-v8a/libopenlistjni.so")
    print("so Java_go_ left:", so.count(b"Java_go_"),
          "| Java_gx_:", so.count(b"Java_gx_"),
          "| go/Seq left:", so.count(b"go/Seq"),
          "| gx/Seq:", so.count(b"gx/Seq"))
    print("so exports openlistcore invoke:",
          b"Java_openlistcore_Openlistcore_invoke" in so)

    # dlsym goes through .gnu.hash: simulate the lookup the linker performs.
    def hash_lookup(blob: bytes, target: bytes):
        is64, secs, sec_name = _elf_sections(blob)
        named2 = {sec_name(s["name"]): s for s in secs}
        ds, dr, gh = named2[".dynsym"], named2[".dynstr"], named2[".gnu.hash"]
        strs = blob[dr["offset"]:dr["offset"] + dr["size"]]
        ent2 = ds["entsize"] or (24 if is64 else 16)
        syms = []
        for k in range(ds["size"] // ent2):
            o = struct.unpack_from("<I", blob, ds["offset"] + k * ent2)[0]
            e = strs.find(b"\0", o)
            syms.append(strs[o:e])
        nb, so_off, bs, shift = struct.unpack_from("<IIII", blob, gh["offset"])
        w = 8 if is64 else 4
        b_off = gh["offset"] + 16 + bs * w
        c_off = b_off + nb * 4
        h = gnu_hash(target)
        idx = struct.unpack_from("<I", blob, b_off + (h % nb) * 4)[0]
        if idx < so_off:
            return False
        while idx < len(syms):
            c = struct.unpack_from("<I", blob, c_off + (idx - so_off) * 4)[0]
            if (c | 1) == (h | 1) and syms[idx] == target:
                return True
            if c & 1:
                return False
            idx += 1
        return False

    for abi in ("arm64-v8a", "armeabi-v7a"):
        blob = z.read(f"jni/{abi}/libopenlistjni.so")
        checks = [b"Java_gx_Seq_init", b"Java_gx_Seq_setContext",
                  b"Java_gx_Seq_incGoRef", b"Java_gx_Seq_destroyRef",
                  b"Java_openlistcore_Openlistcore_invoke"]
        print(abi, "hash lookup:",
              {c.decode(): hash_lookup(blob, c) for c in checks})
