#!/usr/bin/env python3
"""Pack an AssetRipper StructsDump into unityz's embedded built-in tree database.

unityz ships the built-in engine-class type trees of specific Unity releases
inside its binary (`src/builtin_trees/<release>.bin`, listed in
`src/builtin_trees.zig`). Each file is one release's StructsDump from
https://github.com/AssetRipper/TypeTreeDumps, parsed exactly like
`structsdump-to-trees.py` and packed into a compact little-endian table.

To add or refresh a release:

    curl -sL https://raw.githubusercontent.com/AssetRipper/TypeTreeDumps/main/StructsDump/release/2022.3.62f2.dump -o 2022.3.62f2.dump
    uv run scripts/structsdump-to-builtin.py 2022.3.62f2.dump -o src/builtin_trees/2022.3.62f2.bin

then add the release to the table in `src/builtin_trees.zig`. The output is
deterministic for a given dump.

Layout (all integers little-endian):

    magic "UZBT", u8 format (1), u8 release length, release bytes
    u32 string count, then per string: u16 length, bytes
    u32 class count, then per class: i32 class id, u16 name string,
        u32 first node, u32 node count
    u32 node count, then per node: u8 level, u8 type flags, i16 version,
        i32 byte size, u32 meta flags, u16 type string, u16 name string

Classes are sorted by id; nodes are in pre-order, as the `--trees` format
and `typetree.fromFlatNodes` expect. Abstract classes (no nodes) are omitted.
"""
import argparse
import importlib.util
import pathlib
import struct
import sys

HERE = pathlib.Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("structsdump_to_trees", HERE / "structsdump-to-trees.py")
_mod = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
_spec.loader.exec_module(_mod)
convert = _mod.convert


def pack(trees: dict, release: str) -> bytes:
    class_ids = trees["__class_ids__"]
    strings: dict[str, int] = {}

    def sid(s: str) -> int:
        if s not in strings:
            strings[s] = len(strings)
        return strings[s]

    classes = []
    nodes = bytearray()
    node_count = 0
    for name, cid in sorted(class_ids.items(), key=lambda kv: kv[1]):
        tree = trees.get(name) or []
        if not tree:
            continue
        classes.append((cid, sid(name), node_count, len(tree)))
        for n in tree:
            nodes += struct.pack(
                "<BBhiIHH",
                n["m_Level"],
                n["m_TypeFlags"],
                n["m_Version"],
                n["m_ByteSize"],
                n["m_MetaFlag"],
                sid(n["m_Type"]),
                sid(n["m_Name"]),
            )
        node_count += len(tree)
    if len(strings) > 0xFFFF:
        raise ValueError("more than 65535 distinct strings")

    out = bytearray(b"UZBT")
    rel = release.encode()
    out += struct.pack("<BB", 1, len(rel)) + rel
    out += struct.pack("<I", len(strings))
    for s in strings:  # insertion order == index order
        b = s.encode()
        out += struct.pack("<H", len(b)) + b
    out += struct.pack("<I", len(classes))
    for c in classes:
        out += struct.pack("<iHII", *c)
    out += struct.pack("<I", node_count) + nodes
    return bytes(out)


def main() -> int:
    ap = argparse.ArgumentParser(description="Pack a StructsDump into a unityz built-in tree database.")
    ap.add_argument("dump", help="StructsDump release file, e.g. 2022.3.62f2.dump")
    ap.add_argument("-o", "--output", required=True, help="output .bin path")
    ap.add_argument("--release", help="release name (default: the dump's file stem)")
    args = ap.parse_args()
    release = args.release or pathlib.Path(args.dump).stem
    try:
        text = open(args.dump, encoding="utf-8").read()
    except OSError as e:
        print(f"cannot read {args.dump}: {e}", file=sys.stderr)
        return 1
    data = pack(convert(text), release)
    pathlib.Path(args.output).write_bytes(data)
    print(f"wrote {release}: {len(data)} bytes to {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
