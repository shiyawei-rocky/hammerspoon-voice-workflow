#!/usr/bin/env python3
"""Build weekly/monthly reports from meeting minutes and action archive."""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import re
from collections import Counter, defaultdict
from pathlib import Path

TS_FMT = "%Y-%m-%d %H:%M:%S"
CN_RE = re.compile(r"[\u4e00-\u9fff]{2,8}")


def parse_ts(value: str) -> dt.datetime | None:
    try:
        return dt.datetime.strptime(value, TS_FMT)
    except Exception:
        return None


def read_meetings(meetings_dir: Path) -> list[dict]:
    rows: list[dict] = []
    if not meetings_dir.exists():
        return rows
    for p in sorted(meetings_dir.glob("*/*.json")):
        try:
            data = json.loads(p.read_text(encoding="utf-8", errors="ignore"))
        except Exception:
            continue
        ts = parse_ts(str(data.get("ts", "")))
        if not ts:
            continue
        data["_ts"] = ts
        data["_path"] = str(p)
        rows.append(data)
    return rows


def read_actions(actions_csv: Path) -> list[dict]:
    out: list[dict] = []
    if not actions_csv.exists():
        return out
    with actions_csv.open("r", encoding="utf-8", errors="ignore", newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            ts = parse_ts(str(row.get("ts", "")))
            row["_ts"] = ts
            out.append(row)
    return out


def collect_topics(text: str, topn: int = 12) -> list[str]:
    c = Counter()
    for t in CN_RE.findall(text or ""):
        if t in {"会议", "今天", "我们", "需要", "进行", "可以", "项目", "问题", "输出", "内容"}:
            continue
        c[t] += 1
    return [k for k, _ in c.most_common(topn)]


def render_period(label: str, meetings: list[dict], actions: list[dict]) -> str:
    total = len(meetings)
    action_total = len(actions)
    status_counter = Counter((a.get("status") or "TODO").strip() for a in actions)
    text_corpus = "\n".join(str(m.get("minutes", "")) + "\n" + str(m.get("analysis", "")) for m in meetings)
    topics = collect_topics(text_corpus, 10)

    lines = [
        f"# {label}",
        "",
        f"- 生成时间: {dt.datetime.now().strftime(TS_FMT)}",
        f"- 会议数: {total}",
        f"- 行动项总数: {action_total}",
        "",
        "## 行动状态分布",
    ]
    if status_counter:
        for k, v in status_counter.most_common():
            lines.append(f"- {k}: {v}")
    else:
        lines.append("- 暂无")

    lines.extend(["", "## 高频主题",])
    if topics:
        for t in topics:
            lines.append(f"- {t}")
    else:
        lines.append("- 暂无")

    lines.extend(["", "## 会议清单",])
    if meetings:
        meetings_sorted = sorted(meetings, key=lambda x: x["_ts"], reverse=True)
        for m in meetings_sorted[:30]:
            lines.append(
                f"- {m['_ts'].strftime(TS_FMT)} | trigger={m.get('trigger', '')} | actions={len(m.get('actions') or [])} | {m.get('_path', '')}"
            )
    else:
        lines.append("- 暂无")

    return "\n".join(lines) + "\n"


def period_key_week(ts: dt.datetime) -> str:
    iso = ts.isocalendar()
    return f"{iso.year}-W{iso.week:02d}"


def period_key_month(ts: dt.datetime) -> str:
    return ts.strftime("%Y-%m")


def build_reports(meetings: list[dict], actions: list[dict], out_dir: Path, period: str) -> list[Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    written: list[Path] = []

    if period in ("weekly", "both"):
        m_by_week: dict[str, list[dict]] = defaultdict(list)
        a_by_week: dict[str, list[dict]] = defaultdict(list)
        for m in meetings:
            m_by_week[period_key_week(m["_ts"])].append(m)
        for a in actions:
            ts = a.get("_ts")
            if isinstance(ts, dt.datetime):
                a_by_week[period_key_week(ts)].append(a)
        for wk in sorted(m_by_week.keys()):
            content = render_period(f"项目周报 {wk}", m_by_week[wk], a_by_week.get(wk, []))
            p = out_dir / f"weekly-{wk}.md"
            p.write_text(content, encoding="utf-8")
            written.append(p)
        if m_by_week:
            latest = sorted(m_by_week.keys())[-1]
            latest_p = out_dir / "weekly-latest.md"
            latest_p.write_text(render_period(f"项目周报 {latest}", m_by_week[latest], a_by_week.get(latest, [])), encoding="utf-8")
            written.append(latest_p)

    if period in ("monthly", "both"):
        m_by_month: dict[str, list[dict]] = defaultdict(list)
        a_by_month: dict[str, list[dict]] = defaultdict(list)
        for m in meetings:
            m_by_month[period_key_month(m["_ts"])].append(m)
        for a in actions:
            ts = a.get("_ts")
            if isinstance(ts, dt.datetime):
                a_by_month[period_key_month(ts)].append(a)
        for mk in sorted(m_by_month.keys()):
            content = render_period(f"项目月报 {mk}", m_by_month[mk], a_by_month.get(mk, []))
            p = out_dir / f"monthly-{mk}.md"
            p.write_text(content, encoding="utf-8")
            written.append(p)
        if m_by_month:
            latest = sorted(m_by_month.keys())[-1]
            latest_p = out_dir / "monthly-latest.md"
            latest_p.write_text(render_period(f"项目月报 {latest}", m_by_month[latest], a_by_month.get(latest, [])), encoding="utf-8")
            written.append(latest_p)

    summary = {
        "generated_at": dt.datetime.now().strftime(TS_FMT),
        "meetings": len(meetings),
        "actions": len(actions),
        "files": [str(p) for p in written],
    }
    summary_path = out_dir / "report-index.json"
    summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    written.append(summary_path)
    return written


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--meetings-dir", default=str(Path.home() / ".hammerspoon" / "knowledge" / "meetings"))
    ap.add_argument("--actions-csv", default=str(Path.home() / ".hammerspoon" / "knowledge" / "actions" / "action_items.csv"))
    ap.add_argument("--out-dir", default=str(Path.home() / ".hammerspoon" / "knowledge" / "reports"))
    ap.add_argument("--period", choices=("weekly", "monthly", "both"), default="both")
    args = ap.parse_args()

    meetings = read_meetings(Path(args.meetings_dir).expanduser().resolve())
    actions = read_actions(Path(args.actions_csv).expanduser().resolve())
    written = build_reports(meetings, actions, Path(args.out_dir).expanduser().resolve(), args.period)

    print(f"meetings={len(meetings)}")
    print(f"actions={len(actions)}")
    print(f"files={len(written)}")
    for p in written:
        print(str(p))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

