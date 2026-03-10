# 项目治理与分级管理（Whisper/Hammerspoon）

更新时间：2026-02-10

## 目标
- 以“核心资产”驱动项目迭代，避免功能堆叠导致结构失控。
- 将变更风险前置到分级管理与验收门禁，降低后期熵增。

## 分级模型

### S0 核心资产（主线）
- `~/.hammerspoon/prompts/prompts.json`
- `~/.hammerspoon/prompts/glossary.txt`
- `~/.hammerspoon/knowledge/terms_hotlist.txt`
- `~/.hammerspoon/knowledge/user_profile.md`
- `~/.hammerspoon/knowledge/key_memory.md`
- `~/.hammerspoon/config.lua`（模型路由、provider 与关键开关）

变更门禁（必须满足）：
- 版本号变更（至少更新 `_version` 或文档变更记录）
- JSON/Lua 语法通过
- F7/F5 核心链路冒烟通过

### S1 运行时资产（关键执行链）
- `~/.hammerspoon/init.lua`
- `~/.hammerspoon/services/llm.lua`
- `~/.hammerspoon/services/asr.lua`
- `~/.hammerspoon/whisper_cloud_transcribe.sh`
- `~/.hammerspoon/llm_stream.sh`
- `~/.hammerspoon/whisper_record.sh`

变更门禁：
- `luac -p` / `bash -n` 通过
- 关键热键链路（F5/F7/Alt+E/W/X）至少各 1 次

### S2 数据资产（观察与反馈）
- `~/.hammerspoon/transcripts/*.jsonl`
- `~/.hammerspoon/whisper.log`
- `~/.hammerspoon/transcripts/lexicon_updates.log`

管理策略：
- 仅追加，不手工改历史
- 周级统计、月级归档

### S3 辅助资产（工具与文档）
- `~/.hammerspoon/scripts/*.py`
- `~/.hammerspoon/docs/*`
- `~/.hammerspoon/.archive/*`

管理策略：
- 不得反向依赖 S0/S1 的运行时路径
- 允许试验，但必须可移除

## 文件夹结构建议（从现在开始固定）
- `knowledge/`：核心知识资产（术语/画像/记忆）
- `prompts/`：运行时 Prompt 与词表
- `services/`：运行时服务模块（LLM/ASR/UI）
- `scripts/`：离线构建、统计、同步脚本
- `docs/`：治理、架构、验收标准
- `transcripts/`：行为与输出数据
- `.archive/`：历史快照，不参与运行

## 迭代策略（主线优先）
1. 先改 S0：Prompt、术语、记忆、模型路由。
2. 再改 S1：仅为支撑 S0 效果的最小必要改动。
3. 最后看 S2：用真实数据验证收益（质量、延迟、失败率）。

## 防熵增红线
- 禁止把临时文件长期留在 `prompts/` 与根目录（如 `.tmp`、临时备份）。
- 禁止新增未登记热键与未命名 prompt_key。
- 禁止跨层反向依赖（S3 工具脚本直接耦合 UI 行为）。

## 例行检查（建议每日）
```bash
luac -p ~/.hammerspoon/init.lua ~/.hammerspoon/services/*.lua ~/.hammerspoon/lib/*.lua
python3 ~/.hammerspoon/scripts/reliability_score.py --days 7 --json
python3 ~/.hammerspoon/scripts/f5_report.py --days 7
```

发布门禁补充：
- 若卫生检查出现 `entropy_risk=FOUND`，视为阻断发布（需先清理临时文件再发布）。
