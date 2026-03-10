#!/usr/bin/env python3
"""Build 3 knowledge assets from transcripts:
1) terms_hotlist.txt
2) user_profile.md
3) key_memory.md
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
from collections import Counter
from pathlib import Path
from urllib.parse import urlparse


CN_TOKEN_RE = re.compile(r"[\u4e00-\u9fff]{2,8}")
EN_TOKEN_RE = re.compile(r"[A-Za-z][A-Za-z0-9_./+-]{2,}")
TS_FMT = "%Y-%m-%d %H:%M:%S"


CN_STOP = {
    "这个",
    "那个",
    "我们",
    "你们",
    "可以",
    "需要",
    "一个",
    "还是",
    "然后",
    "已经",
    "目前",
    "以及",
    "如果",
    "因为",
    "没有",
    "就是",
    "这样",
    "这种",
    "不是",
    "进行",
    "处理",
    "问题",
    "内容",
    "输出",
    "输入",
    "文本",
    "模型",
    "脚本",
    "功能",
    "项目",
    "方案",
    "今天",
    "现在",
}

EN_STOP = {
    "the",
    "and",
    "for",
    "with",
    "that",
    "this",
    "you",
    "your",
    "not",
    "all",
    "thanks",
    "thank",
    "output",
    "input",
    "result",
    "final",
}


def parse_ts(s: str) -> dt.datetime | None:
    try:
        return dt.datetime.strptime(s, TS_FMT)
    except Exception:
        return None


def read_transcripts(dir_path: Path, days: int) -> list[dict]:
    now = dt.datetime.now()
    cutoff = now - dt.timedelta(days=max(1, days))
    rows: list[dict] = []
    for p in sorted(dir_path.glob("*.jsonl")):
        for line in p.read_text(encoding="utf-8", errors="ignore").splitlines():
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except Exception:
                continue
            ts = parse_ts(str(row.get("ts", "")))
            if ts and ts >= cutoff:
                rows.append(row)
    return rows


def extract_terms(text: str, cn_counter: Counter, en_counter: Counter) -> None:
    for t in CN_TOKEN_RE.findall(text):
        if t in CN_STOP:
            continue
        cn_counter[t] += 1
    for t in EN_TOKEN_RE.findall(text):
        if len(t) < 3:
            continue
        lower = t.lower().strip(".")
        if lower in EN_STOP:
            continue
        if "/" in t or "\\" in t:
            continue
        if any(lower.endswith(ext) for ext in (".lua", ".md", ".json", ".jsonl", ".txt", ".py", ".sh", ".csv")):
            continue
        if ".com" in lower or ".cn" in lower:
            continue
        # Keep tokens that look like terms: uppercase, mixed, digits, separators.
        if any(ch.isupper() for ch in t) or any(ch.isdigit() for ch in t) or any(ch in t for ch in "/._-"):
            en_counter[t] += 1


def parse_glossary(glossary_path: Path) -> list[tuple[str, str]]:
    pairs: list[tuple[str, str]] = []
    if not glossary_path.exists():
        return pairs
    for line in glossary_path.read_text(encoding="utf-8", errors="ignore").splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        if "=" in s:
            left, right = s.split("=", 1)
            pairs.append((left.strip(), right.strip()))
    return pairs


def extract_table_block(cfg_text: str, table_name: str) -> str:
    marker = f"{table_name} = {{"
    start = cfg_text.find(marker)
    if start < 0:
        return ""
    brace_start = cfg_text.find("{", start)
    if brace_start < 0:
        return ""
    depth = 0
    for idx in range(brace_start, len(cfg_text)):
        ch = cfg_text[idx]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return cfg_text[brace_start : idx + 1]
    return ""


def extract_lua_string(block: str, key: str) -> str:
    if not block:
        return ""
    m = re.search(rf'\b{re.escape(key)}\s*=\s*"([^"]+)"', block)
    return m.group(1).strip() if m else ""


def extract_lua_bool(block: str, key: str) -> bool | None:
    if not block:
        return None
    m = re.search(rf"\b{re.escape(key)}\s*=\s*(true|false)\b", block)
    if not m:
        return None
    return m.group(1) == "true"


def provider_label(value: str) -> str:
    raw = (value or "").strip()
    if not raw:
        return ""
    lowered = raw.lower()
    if "dashscope" in lowered:
        return "DashScope"
    if "siliconflow" in lowered:
        return "SiliconFlow"
    if "moonshot" in lowered:
        return "Moonshot"
    if "glm" in lowered:
        return "GLM"
    if "qwen" in lowered:
        return "Qwen"
    if "kimi" in lowered:
        return "Kimi"
    if raw.startswith("http://") or raw.startswith("https://"):
        host = urlparse(raw).netloc
        return host or raw
    return raw


def config_runtime_snapshot(cfg_text: str) -> dict[str, str | bool]:
    llm_block = extract_table_block(cfg_text, "llm")
    asr_block = extract_table_block(cfg_text, "asr")
    asr_fallback_block = extract_table_block(asr_block, "fallback") if asr_block else ""
    features_block = extract_table_block(cfg_text, "features")

    return {
        "llm_quick_model": extract_lua_string(llm_block, "quick"),
        "llm_fast_model": extract_lua_string(llm_block, "fast"),
        "llm_strong_model": extract_lua_string(llm_block, "strong"),
        "llm_default_model": extract_lua_string(llm_block, "default_model"),
        "llm_endpoint": extract_lua_string(llm_block, "endpoint"),
        "llm_lock_key_sources": extract_lua_bool(llm_block, "lock_key_sources"),
        "llm_strict_keychain_candidates": extract_lua_bool(llm_block, "strict_keychain_candidates"),
        "asr_provider_name": extract_lua_string(asr_block, "provider_name"),
        "asr_model": extract_lua_string(asr_block, "model"),
        "asr_endpoint": extract_lua_string(asr_block, "endpoint"),
        "asr_fallback_enabled": extract_lua_bool(asr_fallback_block, "enabled"),
        "asr_fallback_provider_name": extract_lua_string(asr_fallback_block, "provider_name"),
        "asr_fallback_model": extract_lua_string(asr_fallback_block, "model"),
        "f8_mode": extract_lua_string(features_block, "f8_mode"),
    }


def write_terms(out_path: Path, glossary_pairs: list[tuple[str, str]], cn_top: list[tuple[str, int]], en_top: list[tuple[str, int]]) -> None:
    lines: list[str] = []
    lines.append("# 术语（关键字词）")
    lines.append("")
    lines.append(f"更新于：{dt.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append("来源：transcripts/*.jsonl + prompts/glossary.txt")
    lines.append("")
    lines.append("## 高频术语（中文）")
    for t, n in cn_top:
        lines.append(f"- {t} ({n})")
    lines.append("")
    lines.append("## 高频术语（英文/缩写/路径）")
    for t, n in en_top:
        lines.append(f"- {t} ({n})")
    lines.append("")
    lines.append("## 易错写法映射（来自 glossary）")
    for left, right in glossary_pairs[:200]:
        lines.append(f"- {left} => {right}")
    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def detect_preferences(rows: list[dict], cfg_text: str) -> list[str]:
    prefs: list[str] = []
    runtime = config_runtime_snapshot(cfg_text)
    if 'alt_selection_policy = "selected_first"' in cfg_text:
        prefs.append("文本处理偏好：选中优先，无选区再回退全文。")
    if 'alt_w_use_stream = false' in cfg_text:
        prefs.append("Alt+W 偏好：默认非流式，优先稳定链路。")
    if 'enable_alt_z = false' in cfg_text:
        prefs.append("功能收敛：Alt+Z 默认停用，避免重复功能。")
    if runtime["llm_fast_model"]:
        prefs.append(f"模型偏好：fast 使用 {runtime['llm_fast_model']}，承担高频日常任务。")
    if runtime["llm_strong_model"]:
        prefs.append(f"模型偏好：strong 使用 {runtime['llm_strong_model']}，承担高质量复杂任务。")
    if runtime["f8_mode"]:
        prefs.append(f"一键助手策略：F8 当前运行在 {runtime['f8_mode']} 模式。")

    # signal from transcript text
    corpus = " ".join((str(r.get("input", "")) + " " + str(r.get("output", ""))) for r in rows)
    if "不降档" in corpus or "质量" in corpus:
        prefs.append("质量约束：优先保证文本质量，不接受盲目降档。")
    if "延迟" in corpus or "速率" in corpus:
        prefs.append("性能关注：持续关注端到端延迟与失败率。")
    if runtime["llm_lock_key_sources"] or runtime["llm_strict_keychain_candidates"] or "key" in corpus.lower() or "Keychain" in corpus:
        prefs.append("安全偏好：API Key 走 Keychain，多 key 轮换提升韧性。")
    return prefs


def write_user_profile(out_path: Path, rows: list[dict], cfg_text: str) -> None:
    action_counter = Counter(str(r.get("action", "")) for r in rows if r.get("action"))
    app_counter = Counter(str(r.get("app", "")) for r in rows if r.get("app"))
    prompt_counter = Counter(str(r.get("prompt_key", "")) for r in rows if r.get("prompt_key"))
    output_lens = [len(str(r.get("output", ""))) for r in rows if r.get("output")]
    avg_len = sum(output_lens) / len(output_lens) if output_lens else 0
    p50_len = sorted(output_lens)[len(output_lens) // 2] if output_lens else 0

    prefs = detect_preferences(rows, cfg_text)

    lines: list[str] = []
    lines.append("# 用户画像")
    lines.append("")
    lines.append(f"更新于：{dt.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append("来源：transcripts/*.jsonl + config.lua（自动提炼）")
    lines.append("")
    lines.append("## 使用画像摘要")
    lines.append(f"- 近窗样本数：{len(rows)}")
    lines.append(f"- 输出长度：平均 {avg_len:.1f} 字，P50 {p50_len} 字")
    lines.append("- 高频动作：")
    for k, v in action_counter.most_common(8):
        lines.append(f"  - {k}: {v}")
    lines.append("- 高频应用：")
    for k, v in app_counter.most_common(6):
        lines.append(f"  - {k}: {v}")
    lines.append("- 高频 prompt：")
    for k, v in prompt_counter.most_common(8):
        lines.append(f"  - {k}: {v}")
    lines.append("")
    lines.append("## 关键偏好")
    for p in prefs[:12]:
        lines.append(f"- {p}")
    lines.append("")
    lines.append("## 使用目标（推断）")
    lines.append("- 日常高频沟通与文本润色效率优先。")
    lines.append("- 复杂任务保持高质量输出，避免模型降档带来的表达退化。")
    lines.append("- 在可接受复杂度下持续压缩 F5/F7 链路延迟。")
    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_key_memory(out_path: Path, rows: list[dict], cfg_text: str) -> None:
    recent = rows[-200:]
    corpus = " ".join((str(r.get("input", "")) + " " + str(r.get("output", ""))) for r in recent)
    memories: list[str] = []
    runtime = config_runtime_snapshot(cfg_text)

    if "selected_first" in cfg_text:
        memories.append("文本处理策略已固定为“选中优先，空选区回退全文”。")
    if 'alt_w_use_stream = false' in cfg_text:
        memories.append("Alt+W 默认非流式，流式作为可回退能力保留。")
    if runtime["llm_strong_model"]:
        memories.append(f"strong 模型当前固定为 {runtime['llm_strong_model']}。")
    if runtime["llm_fast_model"]:
        memories.append(f"fast 模型当前固定为 {runtime['llm_fast_model']}。")
    llm_provider = provider_label(str(runtime["llm_endpoint"]))
    if llm_provider:
        memories.append(f"LLM 主通道当前为 {llm_provider}，已启用 key 轮换与限流保护。")
    asr_provider = provider_label(str(runtime["asr_provider_name"]) or str(runtime["asr_endpoint"]))
    if asr_provider and runtime["asr_model"]:
        memories.append(f"ASR 主通道当前为 {asr_provider}（{runtime['asr_model']}）。")
    if runtime["asr_fallback_enabled"]:
        fallback_provider = provider_label(str(runtime["asr_fallback_provider_name"]))
        fallback_model = str(runtime["asr_fallback_model"] or "").strip()
        if fallback_provider and fallback_model:
            memories.append(f"ASR 已启用备链路：{fallback_provider}（{fallback_model}）。")
        elif fallback_provider:
            memories.append(f"ASR 已启用备链路：{fallback_provider}。")

    if "质量" in corpus:
        memories.append("长期偏好：质量优先，优化必须可验证、可回滚。")
    if "延迟" in corpus or "速率" in corpus:
        memories.append("长期关注：持续降低按键到输出的端到端延迟。")
    if "Hamster" in corpus or "hamster" in corpus:
        memories.append("跨端诉求：Hamster、Hammerspoon、GPTs 需要统一 prompt 真源与同步机制。")

    lines: list[str] = []
    lines.append("# 关键记忆")
    lines.append("")
    lines.append(f"更新于：{dt.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append("用途：给润色/分析/转录后处理提供稳定的长期偏好约束。")
    lines.append("")
    lines.append("## 稳定记忆")
    for m in memories[:16]:
        lines.append(f"- {m}")
    lines.append("")
    lines.append("## 使用建议（防副作用）")
    lines.append("- 将本文件作为“弱约束上下文”，不要逐条硬注入每次请求。")
    lines.append("- 仅在 F7/F5 后处理和复杂分析任务中按需抽取 1-3 条相关记忆。")
    lines.append("- 避免把短期偏好写成长期记忆，按周清理一次。")
    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--days", type=int, default=30)
    ap.add_argument("--transcripts-dir", default=str(Path.home() / ".hammerspoon" / "transcripts"))
    ap.add_argument("--glossary", default=str(Path.home() / ".hammerspoon" / "prompts" / "glossary.txt"))
    ap.add_argument("--config", default=str(Path.home() / ".hammerspoon" / "config.lua"))
    ap.add_argument("--out-dir", default=str(Path.home() / ".hammerspoon" / "knowledge"))
    args = ap.parse_args()

    transcripts_dir = Path(args.transcripts_dir).expanduser().resolve()
    glossary_path = Path(args.glossary).expanduser().resolve()
    config_path = Path(args.config).expanduser().resolve()
    out_dir = Path(args.out_dir).expanduser().resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    rows = read_transcripts(transcripts_dir, args.days)
    cn_counter: Counter = Counter()
    en_counter: Counter = Counter()
    for r in rows:
        extract_terms(str(r.get("input", "")), cn_counter, en_counter)
        extract_terms(str(r.get("output", "")), cn_counter, en_counter)

    glossary_pairs = parse_glossary(glossary_path)
    cfg_text = config_path.read_text(encoding="utf-8", errors="ignore") if config_path.exists() else ""

    cn_top = [(k, v) for k, v in cn_counter.most_common(220) if v >= 3]
    en_top = [(k, v) for k, v in en_counter.most_common(220) if v >= 2]

    write_terms(out_dir / "terms_hotlist.txt", glossary_pairs, cn_top[:120], en_top[:120])
    write_user_profile(out_dir / "user_profile.md", rows, cfg_text)
    write_key_memory(out_dir / "key_memory.md", rows, cfg_text)

    print(f"rows={len(rows)}")
    print(f"out={out_dir}")
    print("files=terms_hotlist.txt,user_profile.md,key_memory.md")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
