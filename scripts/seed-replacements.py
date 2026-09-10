#!/usr/bin/env python3
"""Merge config/replacements-seed.json into ~/.config/voicepop/replacements.json.

Seed-only-missing: an entry is added only when no existing entry has the same case-folded
`from`. Existing entries are never modified or reordered. The live file is backed up first.
A file that does not parse is left alone entirely, mirroring Replacements.load's
"do not save over a corrupt file" rule (Corrections.swift:150-154).

Usage: seed-replacements.py [--dry-run] [--seed PATH] [--target PATH]
Prints: added=N skipped=N total=N
"""
import argparse
import json
import os
import pathlib
import shutil
import sys
import time

REPO = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_SEED = REPO / "config" / "replacements-seed.json"
DEFAULT_TARGET = pathlib.Path.home() / ".config" / "voicepop" / "replacements.json"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--seed", default=str(DEFAULT_SEED))
    ap.add_argument("--target", default=str(DEFAULT_TARGET))
    args = ap.parse_args()

    seed_path = pathlib.Path(args.seed)
    target = pathlib.Path(args.target)
    seed = json.loads(seed_path.read_text())

    if target.exists():
        try:
            live = json.loads(target.read_text())
            existing = list(live.get("entries", []))
            version = live.get("version", 1)
        except (json.JSONDecodeError, UnicodeDecodeError) as exc:
            print(f"REFUSING: {target} does not parse ({exc}); left untouched", file=sys.stderr)
            return 2
    else:
        existing = []
        version = seed.get("version", 1)

    have = {str(e.get("from", "")).casefold() for e in existing}
    added = 0
    skipped = 0
    merged = list(existing)
    for entry in seed["entries"]:
        key = str(entry["from"]).casefold()
        if key in have:
            skipped += 1
            continue
        merged.append(entry)
        have.add(key)
        added += 1

    print(f"added={added} skipped={skipped} total={len(merged)}")
    if args.dry_run or added == 0:
        return 0

    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        backup = target.with_name(target.name + ".bak-" + time.strftime("%Y%m%d%H%M%S"))
        shutil.copy2(target, backup)
        print(f"backup={backup}")

    tmp = target.with_name(target.name + ".tmp")
    tmp.write_text(json.dumps({"version": version, "entries": merged}, indent=2, sort_keys=True) + "\n")
    os.replace(tmp, target)
    return 0


if __name__ == "__main__":
    sys.exit(main())
