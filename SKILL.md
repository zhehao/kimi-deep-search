---
name: kimi-deep-search
description: Deep research via Kimi CLI. Triggers - "Kimi 搜一下", "Kimi研究一下", "Kimi deep research"
---

# Kimi Deep Search

用 Kimi CLI 的自动搜索能力实现类 Codex 的深度研究功能。支持结构化报告、增量保存、Token 追踪、结果自动发回对话。

## Features

- ✅ **自动多轮搜索** — Kimi CLI `--yolo` 模式自动调用 SearchWeb/FetchURL
- ✅ **结构化报告** — 固定模板（Executive Summary / Key Findings / Sources / Conclusion）
- ✅ **输出净化** — 自动去除转义字符，生成标准 Markdown
- ✅ **增量保存** — 搜索过程中自动保存中间结果，防超时丢失
- ✅ **智能缓存** — 24 小时内相同查询直接返回缓存结果
- ✅ **Token 追踪** — 估算输入/输出 token 使用量 (1 token ≈ 3 字符)
- ✅ **自动重试** — 超时或服务错误时自动重试 (最多3次，指数退避)
- ✅ **自动发送** — agent 完成后自动发送报告到当前对话（支持所有 channel）
- ✅ **进度通知** — 可选实时进度更新

## 对比 Codex Deep Search

| 功能 | Codex CLI | Kimi Deep Search |
|------|-----------|------------------|
| 多轮深度搜索 | ✅ 原生 `exec --full-auto` | ✅ 脚本包装实现 |
| 自动工具调用 | ✅ | ✅ `--yolo` 模式 |
| 结构化报告 | ⚠️ 自由格式 | ✅ 固定模板 |
| 输出净化 | ⚠️ 需手动处理 | ✅ 自动去除转义 |
| Token 追踪 | ❌ | ✅ |
| 智能缓存 | ❌ | ✅ 24h |
| 自动发送结果 | ⚠️ 需配置 | ✅ 内置支持 |
| 进度通知 | ❌ | ✅ |

## Prerequisites

- Kimi CLI 已安装: `kimi --version`
- 已登录: `kimi login`

## Usage

Agent 执行流程：

1. 用 `exec` 运行 `search.sh`（仅生成报告文件）
2. 脚本完成后，读取 meta JSON 获取统计信息
3. 用 `message` 工具发送摘要 + 文件到当前会话（自动路由到正确的 channel）

### 基本执行

```bash
bash ~/.openclaw/workspace/skills/kimi-deep-search/scripts/search.sh \
  --prompt "NVIDIA Rubin Ultra 供应链分析" \
  --task-name "nvidia-research" \
  --timeout 180
```

### 后台执行 (推荐长查询)

```bash
nohup bash ~/.openclaw/workspace/skills/kimi-deep-search/scripts/search.sh \
  --prompt "你的研究主题" \
  --task-name "research-$(date +%s)" \
  --timeout 300 > /tmp/kimi-search.log 2>&1 &
echo "搜索已启动"
```

### 发送结果到当前会话

脚本完成后，agent 读取报告并用 message 工具发送：

```
读取 <output>.md 的 Executive Summary 部分，提取关键结论。
用 message 工具发送摘要文本，然后用 MEDIA: 指令发送完整报告文件。
```

## Parameters

| Flag | Required | Default | Description |
|------|----------|---------|-------------|
| `--prompt` | ✅ | — | 研究查询主题 |
| `--output` | ❌ | `data/kimi-search-results/<task>.md` | 输出文件路径 |
| `--task-name` | ❌ | `kimi-search-<timestamp>` | 任务标识 |
| `--timeout` | ❌ | `180` | 超时秒数 |
| `--model` | ❌ | `kimi-code/kimi-for-coding` | Kimi 模型 |
| `--verbose` | ❌ | `false` | 详细输出 |
| `--max-retries` | ❌ | `3` | 失败时最大重试次数 |

## 报告模板结构

生成的 Markdown 报告包含以下固定章节：

```markdown
---
task: <task-name>
query: <原始查询>
date: YYYY-MM-DD
time: HH:MM:SS
model: kimi-code/kimi-for-coding
elapsed: 120s
status: completed
tokens:
  input: 1500      # 估算输入 token
  output: 8500     # 估算输出 token
  total: 10000
---

# Deep Search Report

# Executive Summary
[核心结论，含关键数字]

## Background
[研究背景]

## Key Findings

### [子话题1]
[详细发现，关键数据表格，来源标注]

### [子话题2]
...

## Data & Metrics
[汇总数据表格]

## Risk Analysis
[风险因素]

## Sources
- [来源标题](URL) - 来源类型，发布日期
...

## Conclusion
[总结和建议]
```

## Result Files

| 文件 | 说明 |
|------|------|
| `data/kimi-search-results/<task>.md` | 最终研究报告 |
| `data/kimi-search-results/<task>-meta.json` | 任务元数据 (token、状态、耗时、重试次数) |
| `data/kimi-search-results/<task>-raw.txt` | Kimi 原始输出 (调试用) |
| `data/cache/<hash>.json` | 缓存文件 (24h 有效) |

## 示例

### 例 1: 简单同步查询

```bash
bash ~/.openclaw/workspace/skills/kimi-deep-search/scripts/search.sh \
  --prompt "OpenAI o3 模型发布时间" \
  --timeout 60
```

### 例 2: 深度研究

```bash
bash ~/.openclaw/workspace/skills/kimi-deep-search/scripts/search.sh \
  --prompt "英伟达Rubin Ultra架构中PCB供应商竞争格局分析" \
  --task-name "rubin-pcb-research" \
  --timeout 240
```

### 例 3: 后台执行 (适合长查询)

```bash
nohup bash ~/.openclaw/workspace/skills/kimi-deep-search/scripts/search.sh \
  --prompt "2025年AI芯片市场格局深度分析" \
  --task-name "ai-chip-2025" \
  --timeout 300 > /tmp/ai-chip.log 2>&1 &
echo "任务已后台启动"
```

## Troubleshooting

### "kimi: command not found"
```bash
pip install kimi-cli
kimi login
```

### 输出为空或格式混乱
- 检查 `--timeout` 是否足够 (复杂查询建议 180s+)
- 查看 raw 文件: `cat data/kimi-search-results/*-raw.txt`

### 没有收到结果消息
- 脚本不再自动发送消息，结果由 agent 通过 `message` 工具发送到当前会话
- 确认脚本正常完成并生成了报告文件

### Token 使用量过高
- 缩短查询长度
- 减少 `--timeout` 时间
- 启用缓存避免重复查询

### 多次重试后仍然失败
- 检查网络连接和 Kimi CLI 登录状态: `kimi login`
- 调整 `--max-retries` 参数增加重试次数
- 查看详细日志: `--verbose`

### Token 估算准确性
Token 数量为估算值 (约 1 token ≈ 3 字符)，实际使用量可能因模型和语言而异。仅供参考。

## Design Notes

本技能通过以下方式模拟 Codex Deep Research：
1. **提示工程** — 强制结构化输出模板
2. **输出提取** — Python 脚本净化 Kimi 的格式化工单输出
3. **外部包装** — Bash 脚本处理超时、缓存、发送等逻辑
4. **增量保存** — 即使超时也能保留部分结果

相比原生 Codex `exec --full-auto`，本方案的优势：
- 输出格式更可控
- 支持缓存和 Token 追踪
- 结果自动发回对话
- 无需 OpenAI API

劣势：
- 需要外部脚本包装
- 提取逻辑依赖 Kimi 输出格式 (可能需随 CLI 更新调整)
