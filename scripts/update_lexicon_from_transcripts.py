#!/usr/bin/env python3
import argparse
import collections
import difflib
import glob
import json
import os
import re
import subprocess
import sys
import time

CN_RE = re.compile(r"[\u4e00-\u9fff]{2,6}")
EN_RE = re.compile(r"[A-Za-z][A-Za-z0-9_./-]{1,30}")


def extract_terms(text):
    terms = []
    terms.extend(CN_RE.findall(text))
    terms.extend(EN_RE.findall(text))
    return terms


def read_jsonl(path):
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except Exception:
                continue


def update_glossary(glossary_path, terms, apply_changes=True):
    begin = "# === AUTO:TRANSCRIPT BEGIN ==="
    end = "# === AUTO:TRANSCRIPT END ==="
    if os.path.exists(glossary_path):
        with open(glossary_path, "r", encoding="utf-8") as f:
            content = f.read()
    else:
        content = ""

    if begin not in content or end not in content:
        if content and not content.endswith("\n"):
            content += "\n"
        content += begin + "\n" + end + "\n"

    pattern = re.compile(re.escape(begin) + r"[\s\S]*?" + re.escape(end) + r"\n?", re.M)
    match = pattern.search(content)
    old_terms = []
    if match:
        for line in match.group(0).splitlines():
            if line.startswith("#") or line.strip() == "" or line in (begin, end):
                continue
            old_terms.append(line.strip())
    old_set = set(old_terms)
    new_set = set(terms)

    if old_set == new_set:
        return [], [], content, content

    block = begin + "\n"
    block += "# (auto generated from transcript history)\n"
    for term in terms:
        block += term + "\n"
    block += end + "\n"

    new_content = pattern.sub(block, content)

    if apply_changes:
        with open(glossary_path, "w", encoding="utf-8") as f:
            f.write(new_content)

    added = [t for t in terms if t not in old_set]
    removed = [t for t in old_terms if t not in new_set]
    return added, removed, content, new_content


def latinize(term):
    try:
        result = subprocess.run(
            [
                "/usr/bin/osascript",
                "-l",
                "JavaScript",
                "-e",
                'ObjC.import("Foundation"); var args=$.NSProcessInfo.processInfo.arguments; var s=ObjC.unwrap(args.objectAtIndex(5)); var str=$.NSMutableString.alloc.initWithString(s); $.CFStringTransform(str, null, $.kCFStringTransformToLatin, false); $.CFStringTransform(str, null, $.kCFStringTransformStripCombiningMarks, false); console.log(str.js);',
                term,
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except Exception:
        return None
    return None


def make_code(term):
    if EN_RE.fullmatch(term):
        return re.sub(r"[^a-z0-9]+", "", term.lower())[:12]
    latin = latinize(term)
    if not latin:
        return None
    parts = [p for p in re.split(r"\s+", latin) if p]
    initials = "".join([p[0] for p in parts])
    code = re.sub(r"[^a-z]+", "", initials.lower())
    return code[:12] if code else None


def update_rime_phrase(rime_path, terms):
    begin = "# === AUTO:TRANSCRIPT BEGIN ==="
    end = "# === AUTO:TRANSCRIPT END ==="
    if os.path.exists(rime_path):
        with open(rime_path, "r", encoding="utf-8") as f:
            content = f.read()
    else:
        content = "# Rime table\n"

    if begin not in content or end not in content:
        if content and not content.endswith("\n"):
            content += "\n"
        content += begin + "\n" + end + "\n"

    pattern = re.compile(re.escape(begin) + r"[\s\S]*?" + re.escape(end) + r"\n?", re.M)
    match = pattern.search(content)
    old_terms = []
    if match:
        for line in match.group(0).splitlines():
            if line.startswith("#") or line.strip() == "" or line in (begin, end):
                continue
            old_terms.append(line.split("\t", 1)[0].strip())
    old_set = set(old_terms)
    new_set = set(terms)

    if old_set == new_set:
        return [], []

    lines = [begin, "# auto generated from transcript history"]
    for term in terms:
        code = make_code(term)
        if not code:
            continue
        lines.append(f"{term}\t{code}\t80")
    lines.append(end)
    block = "\n".join(lines) + "\n"

    new_content = pattern.sub(block, content)

    with open(rime_path, "w", encoding="utf-8") as f:
        f.write(new_content)

    added = [t for t in terms if t not in old_set]
    removed = [t for t in old_terms if t not in new_set]
    return added, removed


def write_updates_log(log_path, added, removed, label):
    if not added and not removed:
        return
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    with open(log_path, "a", encoding="utf-8") as f:
        f.write(time.strftime("%Y-%m-%d %H:%M:%S") + " " + label + "\n")
        if added:
            f.write("  added: " + ", ".join(added) + "\n")
        if removed:
            f.write("  removed: " + ", ".join(removed) + "\n")


def write_pending_artifacts(pending_dir, old_content, new_content, terms):
    os.makedirs(pending_dir, exist_ok=True)
    ts = time.strftime("%Y%m%d-%H%M%S")
    diff_path = os.path.join(pending_dir, f"glossary-update-{ts}.diff")
    terms_path = os.path.join(pending_dir, f"glossary-update-{ts}.terms.txt")
    diff_lines = difflib.unified_diff(
        old_content.splitlines(),
        new_content.splitlines(),
        fromfile="glossary.current",
        tofile="glossary.candidate",
        lineterm="",
    )
    with open(diff_path, "w", encoding="utf-8") as f:
        f.write("\n".join(diff_lines) + "\n")
    with open(terms_path, "w", encoding="utf-8") as f:
        for term in terms:
            f.write(term + "\n")
    return diff_path, terms_path


def main():
    parser = argparse.ArgumentParser(description="Update glossary from transcript history")
    parser.add_argument("--transcripts", default=os.path.expanduser("~/.hammerspoon/transcripts"))
    parser.add_argument("--glossary", default=os.path.expanduser("~/.hammerspoon/prompts/glossary.txt"))
    parser.add_argument("--min-count", type=int, default=3)
    parser.add_argument("--max-terms", type=int, default=300)
    parser.add_argument("--rime", default=os.path.expanduser("~/Library/Rime/custom_phrase_double.txt"))
    parser.add_argument("--apply", action="store_true", help="apply updates to glossary/rime directly")
    parser.add_argument(
        "--pending-dir",
        default=os.path.expanduser("~/.hammerspoon/knowledge/lexicon/pending"),
        help="where to write pending diff when --apply is not set",
    )
    args = parser.parse_args()

    files = sorted(glob.glob(os.path.join(args.transcripts, "*.jsonl")))
    if not files:
        print("No transcript files found.")
        return 0

    counter = collections.Counter()
    for path in files:
        for row in read_jsonl(path):
            text = row.get("output") or row.get("input") or ""
            for term in extract_terms(text):
                counter[term] += 1

    terms = [t for t, c in counter.most_common() if c >= args.min_count]
    max_terms = args.max_terms if args.max_terms and args.max_terms > 0 else 300
    terms = terms[: max_terms]

    log_path = os.path.join(args.transcripts, "lexicon_updates.log")
    glossary_added, glossary_removed, old_content, new_content = update_glossary(args.glossary, terms, apply_changes=args.apply)
    if glossary_added or glossary_removed:
        if not args.apply:
            diff_path, terms_path = write_pending_artifacts(args.pending_dir, old_content, new_content, terms)
            print(
                "PENDING_APPROVAL glossary_changed added=%d removed=%d diff=%s terms=%s"
                % (len(glossary_added), len(glossary_removed), diff_path, terms_path)
            )
            return 0
        rime_added, rime_removed = update_rime_phrase(args.rime, terms)
    else:
        rime_added, rime_removed = [], []

    write_updates_log(log_path, glossary_added, glossary_removed, "glossary")
    write_updates_log(log_path, rime_added, rime_removed, "rime")
    if glossary_added or glossary_removed or rime_added or rime_removed:
        print("Updated glossary and rime with %d terms." % len(terms))
    else:
        print("No lexicon changes.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
