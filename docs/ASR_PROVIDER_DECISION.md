# ASR 架构与 Provider 选型（2026-02-10）

## 当前状态
- 主链路：阿里云 DashScope（`qwen3-asr-flash`）
- 备链路：SiliconFlow（`Qwen/Qwen3-Omni-30B-A3B-Instruct`）
- 已有能力：多 key、失败切换、请求级重试、音频规范化（16k/mono）
- 目标：在质量不下降前提下，继续降低 F5 延迟并提高抗抖动能力

## 选型原则
1. 中文口语转写质量优先（专有名词、术语鲁棒性）
2. 延迟与稳定性并重（P95 与失败率优先于平均值）
3. 接入成本可控（OpenAI 兼容优先，或可通过 adapter 接入）
4. 成本可接受（不盲目追求最低单价）

## 推荐架构（稳健）
- 当前运行配置（与 `config.lua` 对齐）：
  - 主通道：阿里云 DashScope（保留）
  - 备通道：SiliconFlow（会话级 fallback）
  - 策略：主通道命中错误策略后触发备通道，成功后回到主通道
- 中长期策略（演进方向）：
  - 保持双通道可切换架构
  - 在不改热键入口前提下继续优化延迟与稳定性

## Provider 候选（先后顺序）
1. 阿里云（智能语音交互 / DashScope 体系）
2. 腾讯云 ASR
3. 百度智能云语音识别

> 说明：DeepSeek/Kimi/GLM 更适合文本 LLM，不是 F5 ASR 的优先备份通道。

## 最小落地步骤
1. 先做单通道压测：记录 F5 的 P50/P95、失败率、retry 命中率。
2. 增加备通道 adapter（不改上层热键入口）。
3. 开启“延迟阈值触发备通道”灰度（仅 10%-20% 请求）。
4. 比较 3 天样本后再全量切换策略。

## 决策门槛（建议）
- 若主通道 P95 > 3.5s 且失败率 > 2%，必须启用双通道。
- 若双通道成本上涨 > 40% 且稳定性提升 < 30%，回退到单通道。

## 参考链接
- SiliconFlow API 文档：https://docs.siliconflow.cn/api-reference/chat-completions/chat-completions
- 阿里云语音识别产品页：https://www.aliyun.com/product/ai/speech
- 腾讯云 ASR 产品页：https://cloud.tencent.com/product/asr
- 百度智能云语音识别产品页：https://cloud.baidu.com/product/speech/asr
