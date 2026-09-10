#!/usr/bin/env python3
"""Live release->text tracer.

Polls /tmp/voxtype/state every 1 ms and records every state change, plus a
Darwin-notify event fired by voxtype-clean immediately before it writes
stdout (com.caleb.voicepop.transcript-ready). Prints a JSON object with a
"records" array and a "summary" object on exit (Ctrl-C or --seconds elapsed).

Usage: state_trace.py [--seconds N] [--out PATH]
"""
import argparse
import ctypes
import ctypes.util
import json
import sys
import time

STATE_PATH = "/tmp/voxtype/state"
NOTIFY_NAME = b"com.caleb.voicepop.transcript-ready"


def load_notify():
    path = ctypes.util.find_library("system_notify") or "/usr/lib/system/libsystem_notify.dylib"
    try:
        return ctypes.CDLL(path)
    except OSError:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=60)
    ap.add_argument("--out", default="-")
    args = ap.parse_args()

    print(
        "Hold FN, speak ~5 s, release. Ctrl-C or wait for --seconds.",
        file=sys.stderr,
    )

    notify = load_notify()
    token = ctypes.c_int(-1)
    if notify is not None:
        notify.notify_register_check(NOTIFY_NAME, ctypes.byref(token))

    start = time.monotonic()
    records = []
    last_state = None

    def elapsed_ms():
        return round((time.monotonic() - start) * 1000, 3)

    try:
        while (time.monotonic() - start) < args.seconds:
            try:
                with open(STATE_PATH, "rb") as f:
                    raw = f.read()
                state = raw.decode("utf-8", "replace").strip()
            except OSError:
                time.sleep(0.001)
                continue

            if state != last_state:
                records.append({"t_ms": elapsed_ms(), "state": state})
                last_state = state

            if notify is not None and token.value >= 0:
                check = ctypes.c_int(0)
                rc = notify.notify_check(token, ctypes.byref(check))
                if rc == 0 and check.value != 0:
                    records.append({"t_ms": elapsed_ms(), "event": "transcript_ready"})

            time.sleep(0.001)
    except KeyboardInterrupt:
        pass

    # Build per-cycle summary: recording -> transcribing -> idle, with an
    # optional transcript_ready event in between transcribing and idle.
    summary = []
    cycle = {}
    for rec in records:
        if "state" in rec:
            if rec["state"] == "recording":
                cycle = {"record_t": rec["t_ms"]}
            elif rec["state"] == "transcribing" and "record_t" in cycle:
                cycle["transcribing_t"] = rec["t_ms"]
            elif rec["state"] == "idle" and "transcribing_t" in cycle:
                cycle["idle_t"] = rec["t_ms"]
                record_ms = cycle["transcribing_t"] - cycle["record_t"]
                vad_plus_asr_ms = cycle["transcribing_t"] - cycle["record_t"]
                transcribe_to_idle_ms = cycle["idle_t"] - cycle["transcribing_t"]
                ready_to_idle_ms = None
                if "ready_t" in cycle:
                    ready_to_idle_ms = cycle["idle_t"] - cycle["ready_t"]
                summary.append({
                    "record_ms": record_ms,
                    "vad_plus_asr_ms": vad_plus_asr_ms,
                    "transcribe_to_idle_ms": transcribe_to_idle_ms,
                    "ready_to_idle_ms": ready_to_idle_ms,
                })
                cycle = {}
        elif rec.get("event") == "transcript_ready":
            cycle["ready_t"] = rec["t_ms"]

    out_obj = {"records": records, "summary": summary}
    text = json.dumps(out_obj, indent=2)
    if args.out == "-":
        print(text)
    else:
        with open(args.out, "w") as f:
            f.write(text)


if __name__ == "__main__":
    main()
