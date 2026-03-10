# Findings: Architecture Audit

审计日期: 2026-02-28
范围: init.lua, services/*, config.lua, shell scripts, prompts/

---

## HIGH 严重度

### H1. ASR→Glossary 反馈污染环路

**路径**: ASR误识别 → 写入transcript → 频率统计 → glossary自动更新 → 注入F5流程LLM prompt → 放大错误

**证据**: `scripts/update_lexicon_from_transcripts.py:186-199` 从transcript做频率统计写入glossary（`sync_rime_glossary.sh` 是从Rime词表同步，非频率统计源）; `services/llm.lua:590-598` 在 `opts.use_glossary=true` 时注入system prompt，当前仅F5流程显式传true（`init.lua:1321,1333`）。

**风险**: 持续性ASR错误会被"固化"为术语，污染F5润色链路的LLM输出。

**建议**: glossary更新加人工确认门禁，或设最大条目数+TTL淘汰。

### H2. ASR输出零验证直传LLM

**路径**: `services/asr.lua:478` 仅检查非空，无格式/长度/编码校验 → 乱码、截断、重复片段直接进入LLM prompt。

**风险**: 垃圾输入导致LLM幻觉输出，用户无法区分是ASR错还是LLM错。

**建议**: 添加基础卫生检查（长度上限、UTF-8合法性、重复片段检测）。

---

## MEDIUM 严重度

### M1. hs.reload() 无集中清理

**现状**: reload时以下资源未释放:
- `memory_monitor`: timer + menubar item
- `stream_task`: 进行中的shell进程
- `run_lexicon_update()`: fire-and-forget hs.task
- `services/asr.lua`: inflight请求未invalidate
- `f8.lua:running_tasks`: 无cleanup

**风险**: 每次reload泄漏timer/进程，长期使用后资源累积。

**建议**: 添加 `cleanup_before_reload()` 函数，在所有 `hs.reload()` 调用前执行。

### M2. llm.request 异常时 is_processing 卡死

**路径**: `f8.lua` 中若 `deps.llm.request` 抛出异常（非返回error），`finish_processing()` 永远不会被调用。

**现状**: 依赖 `processing_timeout_sec` 超时兜底（默认30s），但超时值在f8 setup时按值快照，config热更新不生效。

**建议**: llm.request调用包裹pcall，或确认Lua层不会throw。

### M3. /tmp 文件安全

**现状**: ASR和LLM通过 `/tmp/` 文件传递数据，文件名可预测，无权限限制。

**风险**: 本地其他进程可读写这些文件（TOCTOU竞态）。

**建议**: 使用 `mktemp` 生成随机文件名，或改用 `$TMPDIR`。

### M4. Prompt注入风险

**路径**: 用户语音输入直接拼接进LLM prompt，无转义/沙箱。

**现状**: 语音输入场景下利用难度较高（需精确口述注入指令），但理论上可行。

**建议**: 低优先级，记录为已知风险。

### M5. F5链式LLM无中间质量检查

**路径**: F5流程为 `f7_then_quick`（先f7结构化润色再quick_polish）或 `quick_only`（`init.lua:1117-1123,1345-1349`），前一阶段错误直接传入下一阶段。

**现状**: 仅最终输出有quality_gate格式检查，无语义校验。

**建议**: 可在阶段间加长度/相似度基础检查。

---

## LOW 严重度

### L1. llm_stream 内部未调 ensure_idle（低风险）

**现状**: `llm_stream()` 内部直接检查 `is_processing`（`init.lua:827-831`），但所有调用入口已先调 `ensure_idle()`（如 `init.lua:936-939`）。实际运行时有双重保护。

**风险**: 极低。仅当未来新增调用入口忘记前置 ensure_idle 时才会暴露。

### L2. Prompt加载代码重复

**现状**: `init.lua` 和 `services/llm.lua` 各有一份 `load_prompt()` 实现，逻辑相同但独立维护。

**风险**: 修改一处忘记另一处导致行为分歧。

### L3. Glossary与Prompt指令潜在冲突

**现状**: glossary术语表和prompt规则可能给出矛盾指示（如glossary说"保留X"，prompt说"简化X"）。

**风险**: LLM行为不可预测，取决于注意力分配。

---

## 无问题确认

| 检查项 | 结论 |
|--------|------|
| 状态机死锁/竞态 | 无。单线程事件循环 + ensure_idle 互斥，closure-based setter正确 |
| 文件句柄泄漏 | 无。所有文件操作通过shell脚本，自动关闭 |
| RUNTIME_USAGE内存增长 | 可忽略。key空间有界，不会无限增长 |
| 跨模块状态同步 | 正确。f8.lua setter callbacks直接修改init.lua upvalue |
| Timer精度 | 可接受。processing_timeout用hs.timer.doAfter，精度足够 |
