# Eval Score Template

Use this template to evaluate whether a change preserved the intended hotkey boundary and did not silently damage the main chain.

| Sample ID | Hotkey | Fidelity (1-5) | Overreach (1-5, lower is better) | Style Drift (1-5, lower is better) | Readability (1-5) | Latency Feel (1-5) | Language Fidelity (1-5) | Result |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| example | F5 |  |  |  |  |  |  |  |

## Pass criteria

### `F5`
- Fidelity first.
- Overreach should stay near zero.
- Must not convert a question into an answer.
- Must not silently change language.

### `F7`
- Fidelity is more important than polish flair.
- Must not introduce visible persona drift.
- Must not silently change language.

### `Alt+W`
- Strong rewriting is allowed.
- Output should stay meaningfully distinct from `F7` behavior.
- Cross-language rewriting should still require explicit user intent unless configured otherwise.

### `Alt+E`
- Chinese-dominant input should produce English.
- English-dominant input should produce Chinese.
- Code / URLs / names should survive intact.

## Recommended regression habit
- Always evaluate at least one sample for `F5`, `F6`, `F7`, `Alt+E`, and `Alt+W` after meaningful runtime changes.
- Treat runtime chain edits (`init.lua`, `services/`, shell scripts) as incomplete until a small eval pass is recorded.
