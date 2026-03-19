#!/usr/bin/env bash
# Kimi Deep Search - Fixed Version
# Features: JSON escaping, stdin-based prompt, retry logic, token tracking
set -euo pipefail

# Load environment from bashrc (for non-interactive shells)
[[ -f ~/.bashrc ]] && source ~/.bashrc

SKILL_DIR="${HOME}/.openclaw/workspace/skills/kimi-deep-search"
RESULT_DIR="${SKILL_DIR}/data/kimi-search-results"
CACHE_DIR="${SKILL_DIR}/data/cache"
KIMI_BIN="${KIMI_BIN:-$(which kimi 2>/dev/null || echo "kimi")}"

# Parameters
PROMPT=""
OUTPUT=""
MODEL="kimi-code/kimi-for-coding"
TIMEOUT=180
TASK_NAME="kimi-search-$(date +%s)"
VERBOSE=false
MAX_RETRIES=3

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt) PROMPT="$2"; shift 2;;
    --output) OUTPUT="$2"; shift 2;;
    --model) MODEL="$2"; shift 2;;
    --timeout) TIMEOUT="$2"; shift 2;;
    --task-name) TASK_NAME="$2"; shift 2;;
    --verbose) VERBOSE=true; shift;;
    --max-retries) MAX_RETRIES="$2"; shift 2;;
    *) echo "Unknown flag: $1"; exit 1;;
  esac
done

[[ -z "$PROMPT" ]] && { echo "ERROR: --prompt required"; exit 1; }
[[ -z "$OUTPUT" ]] && OUTPUT="${RESULT_DIR}/${TASK_NAME}.md"

mkdir -p "$RESULT_DIR" "$CACHE_DIR" "$(dirname "$OUTPUT")"

STARTED_AT="$(date -Iseconds)"
START_TS=$(date +%s)

# Check cache (24h)
CACHE_KEY=$(echo "$PROMPT" | md5sum | cut -d' ' -f1)
CACHE_FILE="${CACHE_DIR}/${CACHE_KEY}.json"
if [[ -f "$CACHE_FILE" ]]; then
  CACHE_AGE=$(( $(date +%s) - $(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0) ))
  if [[ $CACHE_AGE -lt 86400 ]]; then
    echo "[kimi-deep-search] Cache hit! Using cached result (${CACHE_AGE}s old)"
    cat "$(jq -r '.output' "$CACHE_FILE")" > "$OUTPUT"
    exit 0
  fi
fi

# Metadata - use Python to safely escape JSON
META_FILE="${RESULT_DIR}/${TASK_NAME}-meta.json"
python3 << PYMETA
import json
import sys

meta = {
    "task_name": "${TASK_NAME}",
    "prompt": """${PROMPT}""",
    "output": "${OUTPUT}",
    "started_at": "${STARTED_AT}",
    "status": "running",
    "progress": "initializing"
}

with open('${META_FILE}', 'w', encoding='utf-8') as f:
    json.dump(meta, f, ensure_ascii=False, indent=2)
PYMETA

echo "[kimi-deep-search] Task: $TASK_NAME"
echo "[kimi-deep-search] Query: ${PROMPT:0:80}..."

# Structured research prompt - write to temp file to avoid shell escaping issues
RESEARCH_PROMPT_FILE=$(mktemp)
cat > "$RESEARCH_PROMPT_FILE" << 'RESEARCH_EOF'
你是一位专业的行业研究分析师。请对以下话题进行深度研究：

## 研究主题
__PROMPT_PLACEHOLDER__

## 研究要求
1. 使用 SearchWeb 工具搜索多来源信息
2. 使用 FetchURL 工具读取详细内容
3. 交叉验证不同来源的关键数据
4. 所有关键事实必须标注来源 [来源: URL]

## 输出格式（严格遵循）

# Executive Summary
[2-3段核心结论，包含关键数字和主要发现]

## Background
[研究背景和行业概况]

## Key Findings

### [子话题1名称]
[详细发现，关键数据用表格呈现，重要结论标注来源]

### [子话题2名称]
...

## Data & Metrics
[关键数据汇总表格]

## Risk Analysis
[主要风险因素]

## Sources
- [来源标题](URL) - 来源类型(官方/媒体/分析师/社区)，发布日期
...

## Conclusion
[总结和投资/行动建议]

---
开始研究。
RESEARCH_EOF

# Replace placeholder with actual prompt (using Python for safety)
python3 << PYREPLACE
import sys

with open('$RESEARCH_PROMPT_FILE', 'r', encoding='utf-8') as f:
    content = f.read()

# Replace placeholder with actual prompt
content = content.replace('__PROMPT_PLACEHOLDER__', """${PROMPT}""")

with open('$RESEARCH_PROMPT_FILE', 'w', encoding='utf-8') as f:
    f.write(content)
PYREPLACE

RAW_OUTPUT="${RESULT_DIR}/${TASK_NAME}-raw.txt"

# Progress updater function
update_progress() {
  local status="$1"
  local progress="$2"
  python3 << PYUPDATE
import json

try:
    with open('${META_FILE}', 'r', encoding='utf-8') as f:
        meta = json.load(f)
    meta['status'] = '$status'
    meta['progress'] = '$progress'
    with open('${META_FILE}', 'w', encoding='utf-8') as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)
except Exception as e:
    pass
PYUPDATE
}

# Token tracking variables
INPUT_TOKENS=0
OUTPUT_TOKENS=0

echo "[kimi-deep-search] Starting research with ${TIMEOUT}s timeout..."
update_progress "running" "starting research"

# Retry logic with exponential backoff
RETRY_DELAY=5
EXIT_CODE=0
RETRY_COUNT=0

while [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; do
  EXIT_CODE=0
  echo "[kimi-deep-search] Attempt $((RETRY_COUNT + 1))/$MAX_RETRIES..."

  # Use stdin to pass prompt (more reliable than -p for long prompts)
  # Capture both stdout and stderr for token parsing
  timeout "$TIMEOUT" "$KIMI_BIN" --print --yolo --model "$MODEL" < "$RESEARCH_PROMPT_FILE" > "$RAW_OUTPUT" 2>&1 || EXIT_CODE=$?

  # Check if succeeded
  if [[ $EXIT_CODE -eq 0 ]]; then
    echo "[kimi-deep-search] Research completed successfully"
    break
  fi

  # Check if it's a retryable error
  if [[ $EXIT_CODE -eq 124 ]]; then  # timeout
    echo "[kimi-deep-search] Timeout, retrying..."
  elif grep -q "rate limit\|too many requests\|429\|503\|502" "$RAW_OUTPUT" 2>/dev/null; then
    echo "[kimi-deep-search] Rate limited or service unavailable, retrying..."
  elif [[ $EXIT_CODE -ne 0 ]]; then
    echo "[kimi-deep-search] Error (exit=$EXIT_CODE), retrying..."
  fi

  RETRY_COUNT=$((RETRY_COUNT + 1))

  if [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; then
    DELAY=$((RETRY_DELAY * RETRY_COUNT))
    echo "[kimi-deep-search] Waiting ${DELAY}s before retry..."
    sleep $DELAY
    update_progress "running" "retry attempt $((RETRY_COUNT + 1))"
  fi
done

# Clean up temp file
rm -f "$RESEARCH_PROMPT_FILE"

ELAPSED=$(( $(date +%s) - START_TS ))
echo "[kimi-deep-search] Research completed in ${ELAPSED}s (exit=$EXIT_CODE)"

# Check if raw output is empty or too small
RAW_SIZE=$(stat -c%s "$RAW_OUTPUT" 2>/dev/null || echo 0)
if [[ $RAW_SIZE -lt 100 ]]; then
    echo "[kimi-deep-search] ERROR: Raw output is empty or too small (${RAW_SIZE} bytes)"
    echo "Raw output content:"
    cat "$RAW_OUTPUT"
    exit 1
fi

# Extract and clean content
echo "[kimi-deep-search] Processing output..."
update_progress "processing" "extracting content"

# Estimate tokens (rough approximation: 1 token ≈ 4 characters for English, 2 for Chinese)
# This is a fallback estimation since Kimi CLI doesn't expose token counts
echo "[kimi-deep-search] Estimating token usage..."
PROMPT_CHAR_COUNT=${#PROMPT}
INPUT_TOKENS=$(( PROMPT_CHAR_COUNT / 3 ))  # Rough estimate

# Export variables for Python
export TASK_NAME PROMPT MODEL ELAPSED EXIT_CODE OUTPUT RAW_OUTPUT META_FILE INPUT_TOKENS STARTED_AT RETRY_COUNT

python3 << 'PYEOF'
import re
import json
import os
import sys

# Get variables from environment
TASK_NAME = os.environ.get('TASK_NAME', 'unknown')
PROMPT = os.environ.get('PROMPT', '')
MODEL = os.environ.get('MODEL', 'kimi-code/kimi-for-coding')
ELAPSED = os.environ.get('ELAPSED', '0')
EXIT_CODE = int(os.environ.get('EXIT_CODE', '0'))
OUTPUT = os.environ.get('OUTPUT', 'output.md')
RAW_OUTPUT = os.environ.get('RAW_OUTPUT', 'raw.txt')
META_FILE = os.environ.get('META_FILE', 'meta.json')
INPUT_TOKENS = int(os.environ.get('INPUT_TOKENS', '0'))

def extract_report(content):
    """Extract clean report from Kimi output.

    The actual report is inside a TextPart block near the end of output.
    We find the last TextPart that contains a markdown heading.
    """
    # Match TextPart blocks specifically
    text_part_pattern = re.compile(
        r"TextPart\(\s*\n\s*type='text',\s*\n\s*text='(.*?)'\s*\n\)",
        re.DOTALL
    )
    parts = list(text_part_pattern.finditer(content))

    # Find the last part with a markdown heading (that's the final report)
    report_text = None
    for part in reversed(parts):
        text = part.group(1)
        text = text.replace('\\n', '\n')
        text = text.replace('\\"', '"')
        if re.search(r'^#+ ', text, re.MULTILINE):
            report_text = text
            break

    if report_text:
        # Find where the first heading is and start from there
        heading_match = re.search(r'^#+ ', report_text, re.MULTILINE)
        if heading_match:
            report_text = report_text[heading_match.start():]
        return report_text.strip()

    # Fallback: search for the last occurrence of a report heading in raw content
    content_unescaped = content.replace('\\n', '\n')
    # Find all '# ...\n' occurrences that look like report headings
    matches = list(re.finditer(r'^# [^\n]+报告', content_unescaped, re.MULTILINE))
    if matches:
        last_match = matches[-1]
        return content_unescaped[last_match.start():].strip()

    return content

def clean_markdown(text):
    """Clean up markdown formatting."""
    # Remove escape sequences
    text = text.replace('\\n', '\n')
    text = text.replace('\\t', '\t')
    text = text.replace('\\"', '"')
    text = text.replace("\\'", "'")
    text = text.replace('\\`', '`')
    
    # Fix common issues
    text = re.sub(r'\n{4,}', '\n\n\n', text)  # Remove excessive newlines
    text = re.sub(r' +\n', '\n', text)  # Remove trailing spaces
    
    return text.strip()

try:
    # Read raw output
    with open(RAW_OUTPUT, 'r', encoding='utf-8') as f:
        raw = f.read()
    
    # Extract report
    report = extract_report(raw)
    report = clean_markdown(report)

    # If report is empty, use raw output as fallback
    if len(report) < 100:
        report = raw
        # Try to find markdown content
        if '# ' in report:
            first_heading = report.find('# ')
            report = report[first_heading:]

    # Estimate output tokens (rough approximation)
    OUTPUT_TOKENS = len(report) // 3

    # Add YAML frontmatter with token info
    status_str = "completed" if EXIT_CODE == 0 else "timeout/interrupted"
    final_output = f"""---
task: {TASK_NAME}
query: {PROMPT[:200]}...
date: {__import__('datetime').datetime.now().strftime('%Y-%m-%d')}
time: {__import__('datetime').datetime.now().strftime('%H:%M:%S')}
model: {MODEL}
elapsed: {ELAPSED}s
status: {status_str}
tokens:
  input: {INPUT_TOKENS}
  output: {OUTPUT_TOKENS}
  total: {INPUT_TOKENS + OUTPUT_TOKENS}
---

# Deep Search Report

{report}

---
_Generated by Kimi Deep Search_"""
    
    with open(OUTPUT, 'w', encoding='utf-8') as f:
        f.write(final_output)
    
    print(f"Extracted {len(report)} characters to {OUTPUT}")
    
    # Count sections
    sections = re.findall(r'^#+ ', report, re.MULTILINE)
    print(f"Found {len(sections)} sections")
    
except Exception as e:
    print(f"ERROR during extraction: {e}", file=sys.stderr)
    # Fallback: copy raw output
    with open(RAW_OUTPUT, 'r', encoding='utf-8') as f:
        raw = f.read()
    with open(OUTPUT, 'w', encoding='utf-8') as f:
        f.write(raw)
PYEOF

# Update metadata with Python (safe JSON handling)
LINES=$(wc -l < "$OUTPUT" 2>/dev/null || echo 0)
FILE_SIZE=$(stat -c%s "$OUTPUT" 2>/dev/null || echo 0)
COMPLETED_AT=$(date -Iseconds)

# Calculate final token estimates
INPUT_CHARS=${#PROMPT}
INPUT_TOKENS=$(( INPUT_CHARS / 3 ))
OUTPUT_TOKENS=$(( FILE_SIZE / 3 ))

echo "[kimi-deep-search] Token estimate - Input: ~${INPUT_TOKENS}, Output: ~${OUTPUT_TOKENS}"

TOTAL_TOKENS=$(( INPUT_TOKENS + OUTPUT_TOKENS ))

# Export all variables needed by Python
export LINES FILE_SIZE COMPLETED_AT INPUT_TOKENS OUTPUT_TOKENS TOTAL_TOKENS META_FILE

python3 << PYMETA
import json
import os

meta = {
    "task_name": os.environ.get('TASK_NAME', ''),
    "prompt": os.environ.get('PROMPT', ''),
    "output": os.environ.get('OUTPUT', ''),
    "started_at": os.environ.get('STARTED_AT', ''),
    "completed_at": os.environ.get('COMPLETED_AT', ''),
    "elapsed_seconds": int(os.environ.get('ELAPSED', 0)),
    "status": "completed" if os.environ.get('EXIT_CODE') == "0" else "timeout",
    "retries": int(os.environ.get('RETRY_COUNT', 0)),
    "lines": int(os.environ.get('LINES', 0)),
    "bytes": int(os.environ.get('FILE_SIZE', 0)),
    "exit_code": int(os.environ.get('EXIT_CODE', 0)),
    "tokens": {
        "input": int(os.environ.get('INPUT_TOKENS', 0)),
        "output": int(os.environ.get('OUTPUT_TOKENS', 0)),
        "total": int(os.environ.get('TOTAL_TOKENS', 0)),
        "note": "estimated (1 token ≈ 3 chars)"
    }
}

with open(os.environ.get('META_FILE', 'meta.json'), 'w', encoding='utf-8') as f:
    json.dump(meta, f, ensure_ascii=False, indent=2)
PYMETA

# Save to cache
cp "$META_FILE" "$CACHE_FILE"

echo "[kimi-deep-search] Done! Output: $OUTPUT"
exit $EXIT_CODE
