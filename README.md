# Hammerspoon Voice + Text Workflow

A public-safe Hammerspoon setup for dictation, prompt-driven rewriting, ASR/LLM relay, and lightweight workflow automation.

## Positioning
This repo is **not** meant to be a full commercial product or a perfect turnkey clone of the private environment. It is a public-safe system export focused on one thing: preserving the main voice-to-text-to-transformation workflow with enough architecture, governance, and examples to understand and extend it safely.

## What this repo includes
- Hammerspoon Lua runtime entrypoints
- service modules for ASR / LLM / UI / workflow helpers
- shell and Python helper scripts
- public governance and architecture docs
- example config and example prompt files

## Public-safe boundary
This public version intentionally excludes private or sensitive assets:
- API keys / tokens / keychain secrets
- private transcripts and logs
- local knowledge and memory files
- private glossary / terminology assets
- private prompt library payloads
- personal machine-specific config values

See also: [`docs/public-safe-export.md`](docs/public-safe-export.md)

## System layering
The private working system uses a layered sedimentation model:
- **L0 runtime truth** — code and runtime prompt/config sources that actually determine behavior
- **L1 working rules** — documents defining hotkey responsibilities and prompt behavior boundaries
- **L2 evaluation & governance** — score templates, governance notes, validation rules, and regression aids

This public repo preserves that shape as far as safely possible.

## Key docs
- [`GUIDING_PRINCIPLES.md`](GUIDING_PRINCIPLES.md) — system goals and non-negotiable operating principles
- [`docs/PROJECT_GOVERNANCE.md`](docs/PROJECT_GOVERNANCE.md) — asset grading and change gates
- [`docs/hotkey_responsibilities.md`](docs/hotkey_responsibilities.md) — what each hotkey is allowed to do
- [`docs/prompt_contracts.md`](docs/prompt_contracts.md) — semantic contract of main prompt families
- [`docs/eval_score_template.md`](docs/eval_score_template.md) — lightweight regression/eval template
- [`docs/public-safe-export.md`](docs/public-safe-export.md) — public export scope and release gate

## Quick start
1. Copy this repo to `~/.hammerspoon`
2. Duplicate `config.example.lua` to `config.lua`
3. Fill in your own model endpoints, env vars, and keychain settings
4. Duplicate `prompts/prompts.example.json` to `prompts/prompts.json`
5. Create your own `prompts/glossary.txt` if needed
6. Reload Hammerspoon

## Repo structure
- `init.lua` — main Hammerspoon entry
- `services/` — feature modules
- `scripts/` — helper scripts
- `lib/` — shared Lua helpers
- `docs/` — architecture, governance, and evaluation docs
- `prompts/` — example prompt assets

## Notes
This repository is a sanitized open-source export from a private working setup. If something references local-only data, replace it with your own configuration and data sources.
