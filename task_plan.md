# Hammerspoon 项目优化 — 执行状态（含证据闭环）

## 主计划

### Phase 0 — 死文件清理 + Prompt统一 `complete`

证据:
- 死文件已删除: .archive/, security/, knowledge/evidence/, prompts-v2.json, backup, system_dictation.lua → 全部 GONE
- Prompt统一: 运行时代码中无 prompts-v2/f7_prompt_version 引用（本文档中的历史记录不计）
- Fallback简化: init.lua 中 prompt_* 变量已统一为通用兜底

### Phase 1 — lib/utils.lua + memory_monitor提取 `complete`

证据:
- `lib/utils.lua`: 26行, `init.lua:6` require
- `services/memory_monitor.lua`: 261行, `init.lua:2544` require+start

### Phase 2 — F8提取 + normalize_numbers提取 `complete`

证据:
- `services/f8.lua`: 708行, `init.lua:2427` require
- `lib/normalize_numbers.lua`: 169行, `init.lua:559` require

### Phase 3 — 集中处理状态 `complete`

证据:
- `init.lua:399` finish_processing(), `init.lua:434` start_processing()

### Phase 4 — 合并transform函数 `skipped`

原因: 性价比低，计划中标记为可选

### Phase 5 — 转录+日志轮转 `complete`

证据:
- `config.lua:235` write_md = false
- `init.lua:36-39` whisper.log rotation (>1MB → tail 500)

### Phase 6 — Prompt优化 `complete`

证据:
- f7_polish: 663 chars, f5_asr_post: 375 chars, f5_quick_polish: 193 chars

---

## 架构审计 `complete`

证据:
- findings.md: 10个发现 (2 HIGH, 5 MEDIUM, 3 LOW)
- 交叉审核: 3处表述修正已落实
- 静态复核: 所有行号/文件引用与代码对齐

---

## P0修复 `complete`

### P0-1 Glossary门禁

证据:
- `update_lexicon_from_transcripts.py:36` apply_changes参数
- `update_lexicon_from_transcripts.py:174` write_pending_artifacts()
- 默认不直接写入，需 --apply 落盘

### P0-2 ASR卫生检查

证据:
- `services/asr.lua:5` sanitize_utf8_or_keep
- `services/asr.lua:508` has_repeated_lines()
- `services/asr.lua:528` has_repeated_chunks()

---

## P1修复 `complete`

### P1-a cleanup_before_reload

证据:
- `init.lua:201` hs.reload() 前调用 cleanup_before_reload()
- `init.lua:2550-2555` cleanup_before_reload 定义：清理 stream_task/asr/f8/memory_monitor
- `services/memory_monitor.lua` 新增 M.stop()
- `services/f8.lua` 新增 M.cleanup()

### P1-b llm.request包裹pcall

证据:
- `init.lua:159` safe_llm_request wrapper
- `services/f8.lua:8` safe_llm_request wrapper
- 全部 7 处 llm.request 调用已保护

---

## P2修复 `complete`

### P2-1 /tmp 改用 TMPDIR

证据:
- `config.lua:4-7` 默认值改为 `(os.getenv("TMPDIR") or "/tmp") + ...`
- `init.lua:34,829,830,845,1411` 默认值同步更新

### P2-2 合并 load_prompt

证据:
- `services/llm.lua:723` 新增 M.load_prompt 导出
- `init.lua:339-347` 优先调用 llm.load_prompt，回退本地实现

---

## 静态门禁

- `luac -p` (9个Lua文件): PASS
- `python3 -m py_compile` (update_lexicon_from_transcripts.py): PASS
- 运行验证 (2026-02-28): whisper.log 零error, F5正常, hs.reload()正常

---

## 量化总结

- init.lua: 3637 → 2545行 (-30.0%)
- 主计划: 5 complete + 1 skipped（Phase 4按计划可选）
- 新增模块: 4个 (utils/normalize_numbers/f8/memory_monitor)
- 删除死文件: ~2.5MB
- 审计发现: 10个, P0修复2, P1修复2, P2修复2, 剩余4个 MEDIUM/LOW
