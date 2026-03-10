# Prompt Contracts

This document records the semantic contract of the main prompt families. It is intentionally public-safe: it describes behavior and boundaries without exposing private prompt content, glossary assets, or local preference memory.

## Global fidelity rules
- Unless the entry is explicitly for translation, keep the input language.
- Do not silently turn a question into an answer.
- Do not turn "cleanup" into "summary" or "explanation".
- If uncertain, prefer preserving the original wording over over-editing.

## `f5_asr_post`
- Goal: convert ASR text into minimally readable text.
- Allowed: sentence splitting, punctuation, tiny filler cleanup, only high-confidence correction.
- Not allowed: answering, concluding, numbering, structuring, summarizing, translating, turning it into polished prose.
- Red line: unless the source is already enumerated, do not emit `1. 2. 3.` style output.

## `f7_polish`
- Goal: low-intrusion safe polish.
- Priority: fidelity > continuity > grammar > style.
- Allowed: grammar repair, light de-duplication, local order cleanup, minor disambiguation.
- Not allowed: expansion, tonal inflation, heavy formalization, personality swap, tutorialization, translation.

## `alt_w_articulate` / strong rewrite family
- Goal: explicitly stronger rewriting when the user wants it.
- Allowed: restructure, compress, expand, rewrite for purpose (mail, explanation, proposal, note, etc.).
- Not allowed: pretending to be a faithful transcript cleanup.

## `f6_selection`
- Goal: execute user instruction on top of selected text.
- Allowed: explicit modification plus minimal repair of grammar or logical breakage caused by the edit.
- Not allowed: unrelated rewriting, hidden translation, answer-style output.

## `alt_e_translate`
- Goal: translation between Chinese and English.
- Allowed: sense-preserving translation, sentence restructuring, preserving code / URLs / names.
- Not allowed: meta chatter, refusal without cause, keeping the original language unchanged when translation is required.

## `alt_a_summary`
- Goal: short objective summary.
- Allowed: compress facts while keeping key entities and sequence.
- Not allowed: fabrication, markdown noise, language switching unless asked.

## `alt_c_check`
- Goal: list issues only.
- Allowed: typos, grammar, punctuation, formatting, obvious contradictions.
- Not allowed: full rewrite, tutorial explanation, translation.

## Other structure / critique prompts
These prompts default to preserving input language unless the user explicitly asks otherwise:
- `alt_q_struct`
- `alt_z_steps`
- `alt_x_critique`
- `alt_r_philo`
- `alt_j_fanfou`

## Public-repo boundary
This repository does **not** ship the full private runtime prompt assets. In the private working system, some behavior is also shaped by:
- local `prompts/prompts.json`
- local `prompts/glossary.txt`
- local user/profile memory and knowledge assets

This public document only preserves the behavioral contract, not the private prompt payload itself.
