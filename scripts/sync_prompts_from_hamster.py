#!/usr/bin/env python3
"""Sync prompt values from Hamster script files into prompts.json.

Usage example:
  python3 scripts/sync_prompts_from_hamster.py \
    --mapping prompts/hamster-sync.json \
    --prompts prompts/prompts.json
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import sys
from pathlib import Path
from typing import Any


ASSIGN_RE_TMPL = r"(?:^|[\n\r])\s*(?:var|let|const)\s+{name}\s*=\s*"


def _unescape_quoted(value: str) -> str:
    # Conservative JS-like unescape for common sequences.
    out = (
        value.replace(r"\n", "\n")
        .replace(r"\r", "\r")
        .replace(r"\t", "\t")
        .replace(r"\\", "\\")
        .replace(r"\'", "'")
        .replace(r"\"", '"')
    )
    return out


def _extract_literal(source: str, start: int) -> tuple[str, int] | None:
    if start >= len(source):
        return None
    quote = source[start]
    if quote not in ("`", '"', "'"):
        return None

    i = start + 1
    buf: list[str] = []
    esc = False
    while i < len(source):
        ch = source[i]
        if esc:
            buf.append(ch)
            esc = False
            i += 1
            continue
        if ch == "\\":
            esc = True
            buf.append(ch)
            i += 1
            continue
        if ch == quote:
            raw = "".join(buf)
            if quote == "`":
                # Keep multiline template content as-is, only unescape escaped backtick.
                text = raw.replace(r"\`", "`")
            else:
                text = _unescape_quoted(raw)
            return text, i + 1
        buf.append(ch)
        i += 1
    return None


def extract_variable(script_text: str, variable: str) -> str | None:
    pattern = re.compile(ASSIGN_RE_TMPL.format(name=re.escape(variable)), re.M)
    m = pattern.search(script_text)
    if not m:
        return None
    pos = m.end()
    while pos < len(script_text) and script_text[pos].isspace():
        pos += 1
    parsed = _extract_literal(script_text, pos)
    if not parsed:
        return None
    text, _ = parsed
    return text


def load_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise SystemExit(f"file not found: {path}")
    except json.JSONDecodeError as exc:
        raise SystemExit(f"invalid json: {path}: {exc}")


def resolve_path(raw: str, base: Path) -> Path:
    p = Path(raw).expanduser()
    if not p.is_absolute():
        p = (base / p).resolve()
    return p


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--mapping", required=True, help="mapping json path")
    ap.add_argument("--prompts", required=True, help="target prompts json path")
    ap.add_argument("--dry-run", action="store_true", help="show changes only")
    ap.add_argument("--strict", action="store_true", help="fail on missing extraction")
    args = ap.parse_args()

    mapping_path = Path(args.mapping).expanduser().resolve()
    prompts_path = Path(args.prompts).expanduser().resolve()
    mapping_data = load_json(mapping_path)
    prompts_data = load_json(prompts_path)

    items = mapping_data.get("items")
    if not isinstance(items, list) or not items:
        raise SystemExit("mapping json must contain non-empty 'items' array")

    changed = 0
    failed = 0
    root = mapping_path.parent
    details: list[str] = []

    for idx, item in enumerate(items, start=1):
        if not isinstance(item, dict):
            failed += 1
            details.append(f"[{idx}] invalid item type")
            continue
        prompt_key = item.get("prompt_key")
        script_file = item.get("script_file")
        variable = item.get("variable", "SYSTEM_PROMPT")
        trim = bool(item.get("trim", True))
        if not prompt_key or not script_file:
            failed += 1
            details.append(f"[{idx}] missing prompt_key/script_file")
            continue

        script_path = resolve_path(str(script_file), root)
        try:
            script_text = script_path.read_text(encoding="utf-8")
        except FileNotFoundError:
            failed += 1
            details.append(f"[{idx}] missing script: {script_path}")
            continue

        extracted = extract_variable(script_text, str(variable))
        if extracted is None:
            failed += 1
            details.append(f"[{idx}] variable '{variable}' not found: {script_path}")
            continue
        if trim:
            extracted = extracted.strip()
        if extracted == "":
            failed += 1
            details.append(f"[{idx}] extracted empty prompt: {script_path}")
            continue

        old = prompts_data.get(prompt_key)
        if old != extracted:
            prompts_data[prompt_key] = extracted
            changed += 1
            details.append(f"[{idx}] updated {prompt_key} <- {script_path.name}")
        else:
            details.append(f"[{idx}] unchanged {prompt_key}")

    prompts_data["_last_synced"] = dt.datetime.now().isoformat(timespec="seconds")

    print(f"mapping={mapping_path}")
    print(f"prompts={prompts_path}")
    print(f"changed={changed} failed={failed} total={len(items)}")
    for d in details:
        print(d)

    if failed > 0 and args.strict:
        return 2
    if args.dry_run:
        return 0

    backup = prompts_path.with_suffix(prompts_path.suffix + ".bak-" + dt.datetime.now().strftime("%Y%m%d_%H%M%S"))
    backup.write_text(prompts_path.read_text(encoding="utf-8"), encoding="utf-8")
    tmp = prompts_path.with_suffix(prompts_path.suffix + ".tmp")
    tmp.write_text(json.dumps(prompts_data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(prompts_path)
    print(f"backup={backup}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
