#!/usr/bin/env python3
"""Merge two unityz --trees JSON files into one, for full typeless coverage.

A Mono build strips the class type trees from its serialized files. unityz
has two generators for the --trees format, and each covers half of what a
game needs:

- `scripts/structsdump-to-trees.py` builds trees for Unity's built-in
  classes (Mesh, Texture2D, AnimationClip, ...) from an AssetRipper
  TypeTreeDump for the game's Unity version.
- `unityz managed <dir> --trees out.json` builds trees for the game's own
  MonoBehaviour/ScriptableObject classes from its assemblies.

A typeless file holds both kinds of object, so decoding everything needs
both halves in one file. This script merges them:

    uv run scripts/structsdump-to-trees.py 2021.3.45f2.dump -o class-trees.json
    ./zig-out/bin/unityz managed Game/Game_Data --trees script-trees.json
    uv run scripts/merge-trees.py class-trees.json script-trees.json -o trees.json

The result keeps the class trees and their __class_ids__ map from the dump
and adds the managed file's __script_trees__ and __monoscripts__; later
files override earlier ones for shared keys (use the script trees second,
they are the game-specific truth for their scripts).
"""
import argparse
import json


def main() -> int:
    ap = argparse.ArgumentParser(
        description="merge two unityz --trees JSON files into one"
    )
    ap.add_argument("trees", nargs="+", help="trees JSON files, merged in order")
    ap.add_argument("-o", "--output", required=True, help="output trees JSON path")
    args = ap.parse_args()

    merged: dict = {}
    for path in args.trees:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        # __class_ids__ accumulates (a later file may know more ids), every
        # other top-level field (a class tree, __script_trees__,
        # __monoscripts__) is replaced when both files define it.
        for key, value in data.items():
            if key == "__class_ids__" and isinstance(value, dict):
                merged.setdefault("__class_ids__", {}).update(value)
            else:
                merged[key] = value

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(merged, f)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
