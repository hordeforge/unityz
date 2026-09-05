#!/usr/bin/env python3
"""Convert an AssetRipper TypeTreeDumps StructsDump into a unityz --trees file.

Mono builds of Unity games strip the class type trees from their serialized
files, leaving every object undecodable without `--trees`. This script builds
a trees file for any Unity version from the public AssetRipper TypeTreeDumps
repository (https://github.com/AssetRipper/TypeTreeDumps), so `extract`,
`verify`, and `show` can decode typeless files from that version.

Usage:

    curl -sL https://raw.githubusercontent.com/AssetRipper/TypeTreeDumps/main/StructsDump/release/2022.3.62f2.dump -o 2022.3.62f2.dump
    uv run scripts/structsdump-to-trees.py 2022.3.62f2.dump -o trees-2022.3.62f2.json
    ./zig-out/bin/unityz extract game.unity3d --recursive --trees trees-2022.3.62f2.json

The dump's node lines are `<type> <name> // ... MetaFlag{...}`, one tab per
tree level. Two parse points need care: types may be multi-word
(`unsigned int`, `long long`), and names may contain spaces (`image data`),
so the type is matched against the known multi-word set first and the name
is everything after the type token. The reader's four fields (`m_Type`,
`m_Name`, `m_Level`, `m_MetaFlag`) are emitted together with `m_ByteSize`,
`m_Version` and `m_TypeFlags` (the dump's IsArray bit), plus the
`__class_ids__` name-to-id map. `structsdump-to-builtin.py` packs the same
result into the binary database unityz embeds.

Verified against the real Unity 2022.3.62f2 7DTD data: 197 textures, 13
sprites, and 6 meshes export, and 1586/1588 objects in resources.assets
round-trip clean (the two exceptions stream from an external sidecar file).
"""
import argparse
import json
import re
import sys

MULTI_WORD_TYPES = ["unsigned int", "unsigned long long", "unsigned short", "long long"]

NODE_RE = re.compile(
    r"^(?P<before>.+?)\s+//\s+ByteSize\{(?P<size>[0-9a-fA-F]+)\}, Index\{[0-9a-fA-F]+\}, "
    r"Version\{(?P<version>[0-9a-fA-F]+)\}, IsArray\{(?P<array>[01])\}, MetaFlag\{(?P<meta>[0-9a-fA-F]+)\}$"
)
CLASS_RE = re.compile(r"// classID\{(\d+)\}: (\w+)")


def split_type_name(before: str) -> tuple[str | None, str | None]:
    """Split `<type> <name>` where type may be multi-word and name may
    contain spaces."""
    for mt in MULTI_WORD_TYPES:
        if before.startswith(mt + " "):
            return mt, before[len(mt) + 1 :]
    parts = before.split(None, 1)
    if len(parts) != 2:
        return None, None
    return parts[0], parts[1]


def convert(dump_text: str) -> dict:
    classes: dict[str, list[dict]] = {}
    class_ids: dict[str, int] = {}
    order: list[str] = []
    cur: str | None = None
    for ln in dump_text.split("\n"):
        if ln.startswith("// classID{"):
            m = CLASS_RE.match(ln)
            if m:
                cid, cname = int(m.group(1)), m.group(2)
                class_ids[cname] = cid
                cur = cname
                if cname not in classes:
                    classes[cname] = []
                    order.append(cname)
            continue
        if ln.startswith("//") or not ln.strip() or cur is None:
            continue
        tabs = len(ln) - len(ln.lstrip("\t"))
        m = NODE_RE.match(ln.strip())
        if not m:
            continue
        type_name, name = split_type_name(m.group("before"))
        if type_name is None:
            continue
        classes[cur].append(
            {
                "m_Type": type_name,
                "m_Name": name,
                "m_Level": tabs,
                "m_MetaFlag": int(m.group("meta"), 16),
                # ByteSize is a signed 32-bit hex value: ffffffff means "varies".
                "m_ByteSize": int.from_bytes(bytes.fromhex(m.group("size").zfill(8)), "big", signed=True),
                "m_Version": int(m.group("version"), 16),
                "m_TypeFlags": int(m.group("array")),
            }
        )
    out: dict = {"__class_ids__": class_ids}
    for name in order:
        out[name] = classes[name]
    return out


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Convert an AssetRipper StructsDump into a unityz --trees JSON file."
    )
    ap.add_argument("dump", help="path to a StructsDump release file, e.g. 2022.3.62f2.dump")
    ap.add_argument("-o", "--output", required=True, help="output trees JSON path")
    args = ap.parse_args()

    try:
        text = open(args.dump, encoding="utf-8").read()
    except OSError as e:
        print(f"cannot read {args.dump}: {e}", file=sys.stderr)
        return 1
    out = convert(text)
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(out, f)
    print(f"wrote {len(out) - 1} class trees to {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
