#!/usr/bin/env python3
"""Evidence-driven reliability scoring for Hammerspoon workflow."""

from __future__ import annotations

import argparse
import datetime as dt
import glob
import json
import math
import os
import re
from dataclasses import dataclass
from typing import Dict, List, Tuple


REQUIRED_ACTIONS = [
    "Alt+E - 翻译",
    "Alt+A - 快速摘要",
    "Alt+C - 纠错检查",
    "Alt+W - 深度表达",
    "Alt+Q - 结构化 Prompt",
    "Alt+X - 批判性分析",
    "Alt+R - 探赜索隐",
    "Alt+J - 饭否金句",
    "F5",
    "F6",
    "F7",
    "F8",
]


@dataclass
class TaskQuality:
    total: int = 0
    passed: int = 0

    @property
    def rate(self) -> float:
        if self.total == 0:
            return 0.0
        return self.passed / self.total


def sentence_count(text: str) -> int:
    marks = sum(text.count(ch) for ch in ("。", "！", "？", "!", "?"))
    return marks if marks > 0 else (1 if text.strip() else 0)


def nonempty_lines(text: str) -> List[str]:
    return [line.strip() for line in text.splitlines() if line.strip()]


def check_translate(text: str) -> bool:
    if not text.strip():
        return False
    blocked = ("译文", "translation", "请提供")
    lowered = text.lower()
    return not any(tok in text or tok in lowered for tok in blocked)


def check_summary(text: str) -> bool:
    if not text.strip():
        return False
    if "**" in text or "```" in text:
        return False
    return sentence_count(text) <= 4


def check_checklist(text: str) -> bool:
    value = text.strip()
    if not value:
        return False
    if value == "未发现问题":
        return True
    if "**" in value or re.search(r"^\s*\d+\.", value, flags=re.M):
        return False
    for line in nonempty_lines(value):
        if "：" not in line and ":" not in line:
            return False
    return True


def scan_transcripts(transcript_dir: str, days: int) -> Tuple[List[dict], dt.date, dt.date]:
    files = sorted(glob.glob(os.path.join(transcript_dir, "*.jsonl")))
    if not files:
        return [], dt.date.today(), dt.date.today()

    end_date = dt.date.today()
    start_date = end_date - dt.timedelta(days=max(days - 1, 0))
    events: List[dict] = []

    for path in files:
        name = os.path.basename(path)
        try:
            date_str = name.split(".")[0]
            file_date = dt.datetime.strptime(date_str, "%Y-%m-%d").date()
        except Exception:
            continue
        if not (start_date <= file_date <= end_date):
            continue
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    events.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    return events, start_date, end_date


def scan_log(log_path: str, start_date: dt.date, end_date: dt.date) -> Dict[str, int]:
    stats = {
        "utf8_invalid": 0,
        "normalize_failed": 0,
        "clipboard_pollution": 0,
        "asr_failed": 0,
        "llm_failed": 0,
    }
    if not os.path.exists(log_path):
        return stats

    with open(log_path, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            line = line.strip()
            if len(line) < 10:
                continue
            try:
                line_date = dt.datetime.strptime(line[:10], "%Y-%m-%d").date()
            except Exception:
                continue
            if not (start_date <= line_date <= end_date):
                continue

            if "invalid UTF-8 code" in line:
                stats["utf8_invalid"] += 1
            if "normalize_spoken_numbers failed" in line:
                stats["normalize_failed"] += 1
            if "剪贴板污染检测" in line:
                stats["clipboard_pollution"] += 1
            if "ASR request failed" in line:
                stats["asr_failed"] += 1
            if "llm_refine_failed" in line:
                stats["llm_failed"] += 1
    return stats


def clamp(value: float, low: float = 0.0, high: float = 10.0) -> float:
    return max(low, min(high, value))


def compute_scores(events: List[dict], log_stats: Dict[str, int]) -> Dict[str, float]:
    action_counts: Dict[str, int] = {}
    q_translate = TaskQuality()
    q_summary = TaskQuality()
    q_check = TaskQuality()

    for ev in events:
        action = (ev.get("action") or "").strip()
        output = (ev.get("output") or "")
        action_counts[action] = action_counts.get(action, 0) + 1

        if action == "Alt+E - 翻译":
            q_translate.total += 1
            if check_translate(output):
                q_translate.passed += 1
        elif action == "Alt+A - 快速摘要":
            q_summary.total += 1
            if check_summary(output):
                q_summary.passed += 1
        elif action == "Alt+C - 纠错检查":
            q_check.total += 1
            if check_checklist(output):
                q_check.passed += 1

    total_events = len(events)
    covered = sum(1 for action in REQUIRED_ACTIONS if action_counts.get(action, 0) > 0)
    coverage_ratio = covered / len(REQUIRED_ACTIONS)

    # Completeness: coverage + sample volume.
    completeness = clamp(coverage_ratio * 7.0 + min(total_events / 120.0, 1.0) * 3.0)

    # Stability: penalize hard errors.
    stability_penalty = (
        log_stats["utf8_invalid"] * 1.4
        + log_stats["normalize_failed"] * 1.2
        + log_stats["clipboard_pollution"] * 0.4
        + log_stats["asr_failed"] * 0.8
        + log_stats["llm_failed"] * 0.8
    )
    stability = clamp(10.0 - stability_penalty)

    # Quality proxy: weighted pass rates, conservative defaults when sample low.
    def score_or_default(q: TaskQuality, default: float) -> float:
        if q.total == 0:
            return default
        return q.rate * 10.0

    quality = clamp(
        score_or_default(q_translate, 6.5) * 0.30
        + score_or_default(q_summary, 6.5) * 0.30
        + score_or_default(q_check, 6.0) * 0.40
    )

    overall = clamp(completeness * 0.30 + stability * 0.35 + quality * 0.35)
    return {
        "overall": overall,
        "completeness": completeness,
        "stability": stability,
        "quality": quality,
        "total_events": float(total_events),
        "coverage_ratio": coverage_ratio,
        "covered_actions": float(covered),
        "required_actions": float(len(REQUIRED_ACTIONS)),
        "translate_total": float(q_translate.total),
        "summary_total": float(q_summary.total),
        "check_total": float(q_check.total),
        "translate_pass_rate": q_translate.rate if q_translate.total > 0 else math.nan,
        "summary_pass_rate": q_summary.rate if q_summary.total > 0 else math.nan,
        "check_pass_rate": q_check.rate if q_check.total > 0 else math.nan,
    }


def main() -> int:
    def fmt_rate(rate: float) -> str:
        if math.isnan(rate):
            return "N/A"
        return f"{rate:.1%}"

    parser = argparse.ArgumentParser(description="Score Hammerspoon reliability from transcripts/logs.")
    parser.add_argument("--days", type=int, default=7, help="Lookback window in days (default: 7)")
    parser.add_argument("--transcript-dir", default=os.path.expanduser("~/.hammerspoon/transcripts"))
    parser.add_argument("--log-file", default=os.path.expanduser("~/.hammerspoon/whisper.log"))
    parser.add_argument("--json", action="store_true", help="Output JSON only")
    args = parser.parse_args()

    events, start_date, end_date = scan_transcripts(args.transcript_dir, args.days)
    log_stats = scan_log(args.log_file, start_date, end_date)
    scores = compute_scores(events, log_stats)

    if args.json:
        print(
            json.dumps(
                {
                    "window": {
                        "start": start_date.isoformat(),
                        "end": end_date.isoformat(),
                        "days": args.days,
                    },
                    "scores": scores,
                    "log_stats": log_stats,
                },
                ensure_ascii=False,
                indent=2,
            )
        )
        return 0

    print(f"Window: {start_date.isoformat()} -> {end_date.isoformat()} ({args.days}d)")
    print(
        "Scores: overall={:.2f} completeness={:.2f} stability={:.2f} quality={:.2f}".format(
            scores["overall"], scores["completeness"], scores["stability"], scores["quality"]
        )
    )
    print(
        "Coverage: {:.1%} ({:.0f}/{:.0f}), events={:.0f}".format(
            scores["coverage_ratio"],
            scores["covered_actions"],
            scores["required_actions"],
            scores["total_events"],
        )
    )
    print(
        "Quality pass: translate={} (n={:.0f}), summary={} (n={:.0f}), check={} (n={:.0f})".format(
            fmt_rate(scores["translate_pass_rate"]),
            scores["translate_total"],
            fmt_rate(scores["summary_pass_rate"]),
            scores["summary_total"],
            fmt_rate(scores["check_pass_rate"]),
            scores["check_total"],
        )
    )
    print("Log issues:", ", ".join(f"{k}={v}" for k, v in log_stats.items()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
