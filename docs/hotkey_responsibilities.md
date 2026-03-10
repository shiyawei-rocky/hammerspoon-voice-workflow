# Hotkey Responsibilities

This document describes the public-facing responsibility boundary of each hotkey entry. It exists to make the runtime contract explicit: which shortcut is allowed to rewrite, which must stay faithful, and which is meant for structured transformation.

## Main chain

### `F5` — voice dictation to usable text
- User intent: turn spoken content into usable text while staying close to what was actually said.
- Input: microphone recording.
- Allowed: sentence splitting, basic punctuation, tiny filler-word cleanup, only very-high-confidence corrections.
- Not allowed: answering questions, summarizing, numbering, structural rewriting, explanation, translation, heavy stylistic rewriting.
- Output: replace current input area; may write transcript/log artifacts depending on local private config.
- Fallback: return raw ASR text.

### `F6` — selection + spoken instruction
- User intent: modify selected text according to a spoken instruction.
- Input: selected text + spoken instruction.
- Allowed: apply explicit instruction, plus minimal grammar and continuity repair caused by the edit itself.
- Not allowed: unrelated rewriting, unauthorized translation, detached paraphrasing.
- Output: replace current input area.
- Fallback: keep original text.

### `F7` — safe low-intrusion polish
- User intent: lightly polish text without changing its meaning or persona.
- Input: selected text first, otherwise full capture.
- Allowed: grammar repair, small de-duplication, local word-order cleanup, light disambiguation.
- Not allowed: expansion, tonal inflation, personality swap, tutorialization, translation.
- Output: replace current input area.
- Fallback: keep original text.

## Analysis / transformation hotkeys

### `Alt+E` — translation
- Purpose: bilingual translation.
- Default behavior: detect dominant language and translate between Chinese and English.
- Allowed: sense-preserving translation, sentence restructuring, keeping code / URLs / paths / names intact.
- Not allowed: meta chatter like "translation below", refusing to translate without cause.

### `Alt+W` — strong rewrite
- Purpose: explicit stronger rewriting.
- Allowed: structural reorganization, stronger expression, purpose-driven rewrite.
- Not allowed: pretending to be a faithful cleanup; implicit cross-language rewrite by default.

### `Alt+Q` — structure a vague note into executable steps
- Purpose: convert a fuzzy note into actionable steps.
- Allowed: structured numbered steps, explicit information-gap callout.
- Not allowed: drifting away from the original task.

### `Alt+A` — concise summary
- Purpose: objective short summary.
- Allowed: compress facts while keeping key names, numbers, and order.
- Not allowed: fabrication, markdown noise, translation by default.

### `Alt+C` — checks only
- Purpose: list problems without rewriting the original.
- Allowed: typos, grammar, punctuation, formatting, obvious factual contradiction.
- Not allowed: full rewrite, tutorial explanation, translation.

### `Alt+X` — critique
- Purpose: critical analysis of assumptions and weak reasoning.
- Allowed: expose contradictions, hidden assumptions, weak logic.
- Not allowed: language switching by default.

### `Alt+Z` — task decomposition
- Purpose: break a clear task into steps.
- Allowed: 3–7 steps with small checkpoints.
- Not allowed: changing the original task goal.

### `Alt+R` — dense insight
- Purpose: compact high-density insight writing.

### `Alt+J` — one-line stylized output
- Purpose: single-sentence stylized copy.

## F8 assistant modes

### `F8 digest`
- Purpose: summarize recent records quickly.
- Allowed: summary, highlights, todo extraction.
- Not allowed: fabricating facts or rewriting source records.

### `F8 workflow`
- Purpose: project-level summary / analysis / asset generation.
- Allowed: summary, analysis, optional offline asset-building scripts.
- Not allowed: changing the default semantics of the main F5/F7 chain.

## Design principle

The core boundary is simple:
- `F5` and `F7` prioritize fidelity.
- `F6` prioritizes explicit user instruction.
- `Alt+W` is the main entry intentionally allowed to rewrite strongly.
- `F8` is for aggregation and workflow-level outputs, not inline text replacement semantics.
