#!/usr/bin/env python3
"""Compare two directories of PNGs by decoded raster, with a per-channel tolerance.

Usage:
  png_compare.py A_DIR B_DIR [--tolerance N] [--exclude-from X_DIR]

For every *.png present in both A_DIR and B_DIR, decode to RGBA uint8 and report the
maximum absolute per-channel difference and the number of differing pixels.

  --tolerance N     a file counts as "over" only if its max delta exceeds N (default 1)
  --exclude-from X  skip any file whose A_DIR copy already differs from its X_DIR copy;
                    that file is renderer noise, not a signal (see review-1 BLOCKING 1)

Prints one line per file, then a SUMMARY line. Exit 1 only on a decode/shape/missing error,
so callers gate on the SUMMARY counters rather than the exit status.
"""
import argparse
import pathlib
import sys

import numpy as np
from PIL import Image


def load(path):
    with Image.open(path) as im:
        return np.asarray(im.convert("RGBA"), dtype=np.int16)


def delta(a_path, b_path):
    a = load(a_path)
    b = load(b_path)
    if a.shape != b.shape:
        return None, None
    d = np.abs(a - b)
    return int(d.max()), int((d.max(axis=2) > 0).sum())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("a_dir")
    ap.add_argument("b_dir")
    ap.add_argument("--tolerance", type=int, default=1)
    ap.add_argument("--exclude-from", default=None)
    args = ap.parse_args()

    a_dir = pathlib.Path(args.a_dir)
    b_dir = pathlib.Path(args.b_dir)
    x_dir = pathlib.Path(args.exclude_from) if args.exclude_from else None

    compared = unstable = over = within = errors = 0
    worst = 0

    for a_path in sorted(a_dir.glob("*.png")):
        name = a_path.name
        b_path = b_dir / name
        if not b_path.exists():
            print(f"MISSING {name}")
            errors += 1
            continue
        if x_dir is not None:
            x_path = x_dir / name
            if x_path.exists():
                nd, _ = delta(a_path, x_path)
                if nd is None:
                    print(f"SHAPE {name} (baseline pair)")
                    errors += 1
                    continue
                if nd > 0:
                    print(f"UNSTABLE {name} baseline_delta={nd}")
                    unstable += 1
                    continue
        md, px = delta(a_path, b_path)
        if md is None:
            print(f"SHAPE {name}")
            errors += 1
            continue
        compared += 1
        worst = max(worst, md)
        if md > args.tolerance:
            over += 1
            print(f"OVER {name} maxdelta={md} changed_px={px}")
        else:
            within += 1
            print(f"WITHIN {name} maxdelta={md} changed_px={px}")

    print(
        f"SUMMARY compared={compared} within={within} over={over} "
        f"unstable={unstable} errors={errors} worst_maxdelta={worst}"
    )
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
