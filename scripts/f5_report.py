#!/usr/bin/env python3
"""Generate a compact F5 ASR reliability report from whisper.log."""

from __future__ import annotations

import argparse
import datetime as dt
import re
import statistics
from collections import Counter
from pathlib import Path

TS_RE = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) ")
ASR_REQ_NEW_RE = re.compile(
    r"asr_request provider=([^\s]+) model=([^\s]+) request_ms=(\d+) retry_count=(\d+) provider_status=([^\s]+)"
)
ASR_REQ_OLD_RE = re.compile(
    r"asr_request request_ms=(\d+) retry_count=(\d+) provider_status=([^\s]+)"
)
F5_METRICS_RE = re.compile(
    r"f5_metrics capture_ms=(\d+) est_audio_sec=([0-9A-Za-z_]+) timeout_sec=(\d+)"
)
F5_POST_METRICS_RE = re.compile(
    r"f5_post_metrics prompt_key=([^\s]+) model_type=([^\s]+) post_ms=(\d+) input_chars=(\d+) output_chars=(\d+)"
)


def parse_ts(line: str) -> dt.datetime | None:
    m = TS_RE.match(line)
    if not m:
        return None
    try:
        return dt.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S")
    except ValueError:
        return None


def percentile(values: list[int], p: float) -> int:
    if not values:
        return 0
    sorted_values = sorted(values)
    idx = int(round((len(sorted_values) - 1) * p))
    idx = max(0, min(idx, len(sorted_values) - 1))
    return sorted_values[idx]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--log",
        default=str(Path.home() / ".hammerspoon" / "whisper.log"),
        help="Path to whisper.log",
    )
    parser.add_argument(
        "--days",
        type=int,
        default=7,
        help="Lookback window in days (default: 7)",
    )
    args = parser.parse_args()

    log_path = Path(args.log)
    if not log_path.exists():
        print(f"log not found: {log_path}")
        return 1

    now = dt.datetime.now()
    cutoff = now - dt.timedelta(days=max(1, args.days))

    request_ms: list[int] = []
    retry_counts: list[int] = []
    provider_statuses: Counter[str] = Counter()
    old_format_samples = 0
    new_format_samples = 0
    capture_ms: list[int] = []
    timeout_secs: list[int] = []
    post_ms: list[int] = []
    post_prompt_keys: Counter[str] = Counter()
    post_model_types: Counter[str] = Counter()
    recent_lines = 0

    with log_path.open("r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            ts = parse_ts(line)
            if ts is None or ts < cutoff:
                continue
            recent_lines += 1

            m1_new = ASR_REQ_NEW_RE.search(line)
            if m1_new:
                new_format_samples += 1
                request_ms.append(int(m1_new.group(3)))
                retry_counts.append(int(m1_new.group(4)))
                provider_statuses[m1_new.group(5)] += 1
                continue

            m1_old = ASR_REQ_OLD_RE.search(line)
            if m1_old:
                old_format_samples += 1
                request_ms.append(int(m1_old.group(1)))
                retry_counts.append(int(m1_old.group(2)))
                provider_statuses[m1_old.group(3)] += 1
                continue

            m2 = F5_METRICS_RE.search(line)
            if m2:
                capture_ms.append(int(m2.group(1)))
                timeout_secs.append(int(m2.group(3)))
                continue

            m3 = F5_POST_METRICS_RE.search(line)
            if m3:
                post_prompt_keys[m3.group(1)] += 1
                post_model_types[m3.group(2)] += 1
                post_ms.append(int(m3.group(3)))

    print(f"window_days={args.days}")
    print(f"log={log_path}")
    print(f"lines_in_window={recent_lines}")
    print(f"f5_asr_samples={len(request_ms)}")
    print(f"old_format_samples={old_format_samples}")
    print(f"new_format_samples={new_format_samples}")

    if request_ms:
        ok = sum(1 for s in provider_statuses.elements() if s == "200")
        total = len(request_ms)
        retry_hits = sum(1 for x in retry_counts if x > 0)
        print(f"success_rate={ok}/{total} ({ok * 100.0 / total:.1f}%)")
        print(
            "request_ms:"
            f" avg={statistics.mean(request_ms):.1f}"
            f" p50={percentile(request_ms, 0.50)}"
            f" p95={percentile(request_ms, 0.95)}"
            f" max={max(request_ms)}"
        )
        print(f"retry_hits={retry_hits}/{total} ({retry_hits * 100.0 / total:.1f}%)")
        print("provider_status_distribution:")
        for status, count in provider_statuses.most_common():
            print(f"  {status}: {count}")
    else:
        print("no new asr_request metrics found in this window.")
        print("tip: run F5 10-20 times, then rerun this report.")

    if capture_ms:
        print(
            "capture_ms:"
            f" avg={statistics.mean(capture_ms):.1f}"
            f" p50={percentile(capture_ms, 0.50)}"
            f" p95={percentile(capture_ms, 0.95)}"
            f" max={max(capture_ms)}"
        )
    if timeout_secs:
        print(
            "timeout_sec:"
            f" min={min(timeout_secs)}"
            f" p50={percentile(timeout_secs, 0.50)}"
            f" max={max(timeout_secs)}"
        )
    if post_ms:
        print(f"f5_post_samples={len(post_ms)}")
        print(
            "post_ms:"
            f" avg={statistics.mean(post_ms):.1f}"
            f" p50={percentile(post_ms, 0.50)}"
            f" p95={percentile(post_ms, 0.95)}"
            f" max={max(post_ms)}"
        )
        print("post_prompt_key_distribution:")
        for key, count in post_prompt_keys.most_common():
            print(f"  {key}: {count}")
        print("post_model_type_distribution:")
        for model_type, count in post_model_types.most_common():
            print(f"  {model_type}: {count}")

    if capture_ms and request_ms and post_ms:
        p50_capture = percentile(capture_ms, 0.50)
        p50_asr = percentile(request_ms, 0.50)
        p50_post = percentile(post_ms, 0.50)
        p50_total = p50_capture + p50_asr + p50_post
        if p50_total > 0:
            print(
                "stage_share_p50:"
                f" capture={p50_capture * 100.0 / p50_total:.1f}%"
                f" asr={p50_asr * 100.0 / p50_total:.1f}%"
                f" post={p50_post * 100.0 / p50_total:.1f}%"
            )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
