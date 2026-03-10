# Onboarding

If you are new to this repository, do not start by reading every file. Use this path.

## 5-minute orientation

### Step 1: understand what this repo is
Read:
- `README.md`
- `docs/public-safe-export.md`

Goal: understand that this is a public-safe export, not a full private environment dump.

### Step 2: understand the operating philosophy
Read:
- `GUIDING_PRINCIPLES.md`

Goal: understand the non-negotiables:
- stability first
- do not casually break the main chain
- prefer low-risk incremental changes

### Step 3: understand runtime boundaries
Read:
- `docs/hotkey_responsibilities.md`
- `docs/prompt_contracts.md`

Goal: learn which entries are meant to preserve fidelity and which are allowed to rewrite more aggressively.

### Step 4: understand the code shape
Read:
- `docs/architecture-map.md`
- `init.lua`
- `services/llm.lua`
- `services/asr.lua`

Goal: know where behavior actually comes from.

### Step 5: understand how to validate changes
Read:
- `docs/PROJECT_GOVERNANCE.md`
- `docs/eval_score_template.md`

Goal: avoid changing runtime behavior without a minimal evaluation pass.

## First-time local setup
1. copy repo to `~/.hammerspoon`
2. create `config.lua` from `config.example.lua`
3. create `prompts/prompts.json` from `prompts/prompts.example.json`
4. create your own local glossary if needed
5. configure your own provider keys through env or keychain
6. reload Hammerspoon

## If you want to contribute safely
Start with one of these lower-risk areas:
- README clarity
- docs consistency
- architecture notes
- eval template improvements
- helper script hygiene

Avoid jumping directly into runtime-chain rewrites unless you understand:
- `init.lua`
- `services/llm.lua`
- `services/asr.lua`
- shell relay scripts

## Before you change runtime behavior
Ask yourself:
1. Which hotkey or workflow entry does this affect?
2. Is this runtime truth, working rules, or evaluation/governance?
3. What is the smallest test that proves I did not silently damage F5/F6/F7?

## Rule of thumb
If a change makes the system more clever but less predictable, it is probably the wrong first move.
