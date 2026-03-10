# Hammerspoon Voice + Text Workflow

A public-safe Hammerspoon setup for dictation, prompt-driven rewriting, ASR/LLM relay, and lightweight workflow automation.

## What this repo includes
- Hammerspoon Lua services and entrypoints
- Shell/Python helper scripts
- Public docs describing the architecture
- Example config and example prompt files

## What is intentionally excluded
This public version does **not** include any personal or sensitive data:
- API keys / tokens / keychain secrets
- private transcripts and logs
- local knowledge base and memory files
- glossary / terminology assets
- private prompt library
- personal config values

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
- `docs/` — project notes and architecture
- `prompts/` — example prompt assets

## Notes
This repository is a sanitized open-source export from a private working setup. If something references local-only data, replace it with your own configuration.
