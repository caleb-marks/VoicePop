#!/usr/bin/env python3
"""Bench Whisper small.en vs large-v3-turbo on fixture WAVs (identical audio)."""
from __future__ import annotations

import json
import re
import statistics
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIX = Path(__file__).resolve().parent / "fixtures"
OUT = ROOT / "docs" / "bench-results.json"
VOXTYPE = "/opt/homebrew/bin/voxtype"


def normalize(s: str) -> list[str]:
    s = s.lower()
    s = re.sub(r"[^a-z0-9\s]", " ", s)
    return [w for w in s.split() if w]


def wer(ref: str, hyp: str) -> float:
    r = normalize(ref)
    h = normalize(hyp)
    if not r:
        return 0.0 if not h else 1.0
    # classic Levenshtein on word lists
    dp = [[0] * (len(h) + 1) for _ in range(len(r) + 1)]
    for i in range(len(r) + 1):
        dp[i][0] = i
    for j in range(len(h) + 1):
        dp[0][j] = j
    for i in range(1, len(r) + 1):
        for j in range(1, len(h) + 1):
            cost = 0 if r[i - 1] == h[j - 1] else 1
            dp[i][j] = min(dp[i - 1][j] + 1, dp[i][j - 1] + 1, dp[i - 1][j - 1] + cost)
    return dp[-1][-1] / len(r)


def transcribe(model: str, wav: Path) -> tuple[str, float]:
    t0 = time.perf_counter()
    r = subprocess.run(
        [VOXTYPE, "--model", model, "--engine", "whisper", "transcribe", str(wav)],
        capture_output=True,
        text=True,
        timeout=300,
    )
    dt = time.perf_counter() - t0
    # Transcript is the last non-empty stdout line that isn't a status prefix
    lines = [ln.strip() for ln in (r.stdout or "").splitlines() if ln.strip()]
    text = ""
    for ln in reversed(lines):
        if ln.startswith(("Loading", "Audio", "Processing", "VAD:", "whisper_", "ggml_")):
            continue
        text = ln
        break
    return text, dt


def p95(xs: list[float]) -> float:
    if not xs:
        return float("nan")
    s = sorted(xs)
    idx = min(len(s) - 1, int(round(0.95 * (len(s) - 1))))
    return s[idx]


def main() -> None:
    manifest = json.loads((FIX / "manifest.json").read_text())
    # Warm once each
    sample = FIX / manifest[0]["wav"]
    for m in ("small.en", "large-v3-turbo"):
        transcribe(m, sample)

    results = {}
    for model in ("small.en", "large-v3-turbo"):
        times = []
        wers = []
        name_hits = 0
        name_total = 0
        rows = []
        for item in manifest:
            wav = FIX / item["wav"]
            hyp, dt = transcribe(model, wav)
            w = wer(item["text"], hyp)
            times.append(dt)
            wers.append(w)
            if "ada" in item["text"].lower() or "voicepop" in item["text"].lower():
                name_total += 1
                ok = ("ada" in hyp.lower() if "ada" in item["text"].lower() else True)
                ok = ok and ("voicepop" in hyp.lower().replace(" ", "") if "voicepop" in item["text"].lower() else True)
                # softer check: tokens present
                ref_toks = set(normalize(item["text"]))
                hyp_toks = set(normalize(hyp))
                critical = {t for t in ("ada", "lovelace", "voicepop", "february") if t in ref_toks}
                if critical:
                    name_total += 0  # already counted
                    if critical <= hyp_toks:
                        name_hits += 1
            rows.append({"id": item["id"], "ref": item["text"], "hyp": hyp, "wer": w, "sec": dt})
        results[model] = {
            "n": len(manifest),
            "wer_mean": statistics.mean(wers),
            "wer_median": statistics.median(wers),
            "latency_median_s": statistics.median(times),
            "latency_p95_s": p95(times),
            "rows": rows,
        }

    base = results["small.en"]
    turbo = results["large-v3-turbo"]
    speedup = base["latency_p95_s"] / turbo["latency_p95_s"] if turbo["latency_p95_s"] else 0
    select_turbo = (
        turbo["latency_p95_s"] <= base["latency_p95_s"] * 0.75
        and turbo["wer_mean"] <= base["wer_mean"] * 1.02
    )
    decision = {
        "select": "large-v3-turbo" if select_turbo else "small.en",
        "reason": (
            "turbo meets ≥25% faster warm p95 and no WER regression"
            if select_turbo
            else "retain baseline: turbo did not improve both speed and accuracy enough"
        ),
        "speed_ratio_baseline_over_turbo_p95": speedup,
        "wer_delta": turbo["wer_mean"] - base["wer_mean"],
    }
    payload = {"results": {k: {kk: vv for kk, vv in v.items() if kk != "rows"} for k, v in results.items()}, "decision": decision, "detail_path": "docs/bench-results.full.json"}
    OUT.write_text(json.dumps(payload, indent=2))
    (ROOT / "docs" / "bench-results.full.json").write_text(json.dumps({"results": results, "decision": decision}, indent=2))
    print(json.dumps(payload, indent=2))


if __name__ == "__main__":
    main()
