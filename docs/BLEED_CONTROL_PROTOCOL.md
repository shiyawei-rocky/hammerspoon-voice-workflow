# Bleed Control Protocol

## Purpose
Convert subjective tuning into an objective control loop with hard anchors and explicit escape routes.

## Status
- The original `control_gate.py` / `failsafe_profile.py` toolchain is not present in the current repo.
- This document is therefore a manual operating protocol, not an executable automation spec.

## Hard Anchors
- `observe` window: fixed 30 minutes.
- `fix` window: fixed 90 minutes.
- Any tuning in the `fix` window must be reversible through `config.lua`.

## Current Manual Baseline
Before a risky change, save these artifacts:
- `config.lua`
- `prompts/prompts.json`
- `prompts/glossary.txt`
- `whisper.log` tail sample
- `scripts/reliability_score.py --days 7 --json`
- `scripts/f5_report.py --days 7`

Suggested commands:
```bash
cp ~/.hammerspoon/config.lua /tmp/config.lua.backup
cp ~/.hammerspoon/prompts/prompts.json /tmp/prompts.json.backup
python3 ~/.hammerspoon/scripts/reliability_score.py --days 7 --json
python3 ~/.hammerspoon/scripts/f5_report.py --days 7
tail -n 200 ~/.hammerspoon/whisper.log
```

## Independent Judge
Use objective metrics only:
- LLM 401 / key exhaustion signals
- F5 overhead p95 (`asr_request p95 + f5_post p95`)
- F8 stage failures
- fatal runtime errors

Practical thresholds:
- `PASS`: no fatal errors, F5 可正常完成，近期指标无明显恶化
- `DEGRADE`: 可用但波动明显，需要收缩功能面
- `ROLLBACK`: 主链路失败或副作用不可控，立即回退配置

## Current Escape Routes
The current repo can safely degrade by editing only these switches in `config.lua`:
- `features.f5_refine_pipeline`
- `features.f8_mode`
- `features.enable_f8_commands`
- `llm.safe_key_limit`
- `llm.lock_key_sources`
- `llm.strict_keychain_candidates`
- `asr.fallback.enabled`

Recommended degrade order:
1. 收缩 `features.f8_mode` 到 `digest`
2. 关闭 `features.enable_f8_commands` 或会议自动链路
3. 将 `features.f5_refine_pipeline` 调整为 `quick_only`
4. 收紧 `llm.safe_key_limit`
5. 必要时关闭 `asr.fallback.enabled`

## Reload Requirement
After changing `config.lua` or prompts, reload Hammerspoon for the new profile to take effect.
