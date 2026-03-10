# Architecture Map

This document is the shortest way to understand how the repository is structured and how the main runtime chain flows.

## Top-level mental model

The system is a Hammerspoon-centered glue layer that connects:
1. input capture
2. ASR / transcription
3. LLM text transformation
4. UI feedback / paste-back
5. optional workflow-level aggregation

The design goal is not maximal abstraction. The goal is to keep the main chain stable, inspectable, and easy to repair.

## Main runtime chain

### F5
Microphone recording -> ASR script -> text post-processing -> optional safe polish -> paste to current app

### F6
Selected text + spoken instruction -> LLM execution -> optional safe polish -> replace selected text

### F7
Selected text -> safe polish -> replace selected text

### F8
Recent local records -> digest/workflow analysis -> archived or clipboard-ready output

## Repository map by role

### Runtime truth (closest to L0)
- `init.lua`
  - main entrypoint
  - hotkey wiring
  - top-level orchestration
- `services/`
  - runtime service modules
  - `asr.lua` — ASR provider wiring and fallback logic
  - `llm.lua` — prompt loading, model routing, LLM execution behavior
  - `ui.lua` — HUD / UI feedback helpers
  - `f8.lua` — digest / workflow-level assistant
  - `meeting_assistant.lua` — meeting-oriented processing hooks
  - `memory_monitor.lua`, `rime_bridge.lua` — auxiliary runtime helpers
- `llm_stream.sh`
  - shell-side LLM relay / stream helper
- `whisper_cloud_transcribe.sh`
  - shell-side ASR relay helper
- `whisper_record.sh`
  - recording helper

### Shared helper layer
- `lib/`
  - small reusable Lua helpers
  - normalization / utility logic

### Public-safe config and prompt examples
- `config.example.lua`
  - example runtime config only
- `prompts/prompts.example.json`
  - example prompt payloads only
- `prompts/hamster-sync.example.json`
  - example sync mapping only

### Offline scripts / support tooling
- `scripts/`
  - reporting, reliability scoring, prompt sync, glossary sync, asset building
  - these support the system, but should not silently redefine runtime semantics on their own

### Governance / evaluation / architecture
- `GUIDING_PRINCIPLES.md`
  - system intent and non-negotiable principles
- `docs/PROJECT_GOVERNANCE.md`
  - asset grading and change gates
- `docs/hotkey_responsibilities.md`
  - entry-by-entry behavioral boundaries
- `docs/prompt_contracts.md`
  - prompt-family semantic contracts
- `docs/eval_score_template.md`
  - minimal eval pass template
- `docs/public-safe-export.md`
  - explains public/private boundary

## Public repo vs private working system

This public repository preserves:
- runtime shape
- module boundaries
- governance logic
- example configuration shape
- evaluation intent

It does **not** include:
- private config
- private glossary
- private prompt library payloads
- transcripts / logs / personal memory assets

So the public repo is best understood as:
- a public-safe architecture export
- a runnable starting point after local setup
- not a fully identical clone of the private system

## Change risk map

### Highest-risk files
Changes here are most likely to affect user-facing behavior:
- `init.lua`
- `services/asr.lua`
- `services/llm.lua`
- `llm_stream.sh`
- `whisper_cloud_transcribe.sh`
- `whisper_record.sh`

### Medium-risk files
- `services/ui.lua`
- `services/f8.lua`
- `config.example.lua` (for public understanding only)
- helper scripts that influence generated assets

### Lower-risk files
- docs
- README polish
- public-safe example assets

## Recommended reading order for a new maintainer
1. `README.md`
2. `GUIDING_PRINCIPLES.md`
3. `docs/PROJECT_GOVERNANCE.md`
4. `docs/hotkey_responsibilities.md`
5. `docs/prompt_contracts.md`
6. `init.lua`
7. `services/llm.lua`
8. `services/asr.lua`
9. shell helpers
