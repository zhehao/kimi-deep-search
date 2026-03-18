#!/usr/bin/env bash
# Deep search via Kimi CLI - Simple version that extracts final answer
set -euo pipefail

SKILL_DIR="${HOME}/.openclaw/workspace/skills/kimi-deep-search"
RESULT_DIR="${SKILL_DIR}/data/kimi-search-results"
OPENCLAW_BIN="${HOME}/.npm-global/bin/openclaw"
KIMI_BIN="${KIMI_BIN:-$(which kimi 2>/dev/null || echo "kimi")}"

PROMPT=""
OUTPUT=""
MODEL="kimi-code/kimi-for-coding"
TIMEOUT=180
TELEGRAM_GROUP=""
TASK_NAME="kimi-search-$(date +%s)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt) PROMPT="$2"; shift 2;;
    --output) OUTPUT="$2"; shift 2;;
    --model) MODEL="$2"; shift 2;;
    --timeout) TIMEOUT="$2"; shift 2;;
    --telegram-group) TELEGRAM_GROUP="$2"; shift 2;;
    --task-name) TASK_NAME="$2"; shift 2;;
    *) echo "Unknown flag: $1"; exit 1;;
  esac
done

[[ -z "$PROMPT" ]] && { echo "ERROR: --prompt required"; exit 1; }
[[ -z "$OUTPUT" ]] && OUTPUT="${RESULT_DIR}/${TASK_NAME}.md"

mkdir -p "$RESULT_DIR"
mkdir -p "$(dirname "$OUTPUT")"

STARTED_AT="$(date -Iseconds)"

echo "[kimi-deep-search] Task: $TASK_NAME"
echo "[kimi-deep-search] Query: $PROMPT"
echo "[kimi-deep-search] Output: $OUTPUT"
echo "[kimi-deep-search] Model: $MODEL | Timeout: ${TIMEOUT}s"

# Simple prompt - Kimi does the research and outputs directly
RESEARCH_PROMPT="Conduct deep research on the following topic and provide a comprehensive report:

TOPIC: ${PROMPT}

Requirements:
1. Search multiple sources using web search
2. Cross-reference information for accuracy
3. Include source URLs for key facts
4. Structure your response with:
   - Executive Summary
   - Detailed Findings (with sections)
   - Sources
   - Conclusion

Write your complete response below:"

RAW_OUTPUT="${RESULT_DIR}/${TASK_NAME}-raw.txt"

# Run Kimi
EXIT_CODE=0
timeout "${TIMEOUT}" "$KIMI_BIN" \
  --print \
  --yolo \
  --model "$MODEL" \
  -p "$RESEARCH_PROMPT" > "$RAW_OUTPUT" 2>&1 || EXIT_CODE=$?

echo "[kimi-deep-search] Kimi finished (exit=$EXIT_CODE), extracting content..."

# Extract content - look for the actual report (skip metadata)
python3 - "$RAW_OUTPUT" "$OUTPUT" << 'PYEOF'
import sys

input_file, output_file = sys.argv[1], sys.argv[2]
content = open(input_file, 'r', encoding='utf-8').read()

# Split by common markers and extract the research content
# Strategy: Find content after "Write your complete response below:" or similar
markers = [
    "Write your complete response below:",
    "Start researching NOW",
    "I'll help you research",
]

final_text = None
for marker in markers:
    idx = content.find(marker)
    if idx >= 0:
        candidate = content[idx + len(marker):].strip()
        # Skip if it's just metadata
        if len(candidate) > 500 and "TurnBegin(" not in candidate[:200]:
            final_text = candidate
            break
        # If has TurnBegin, try to extract from after the prompt section
        if "TurnBegin(" in candidate:
            # Find the first TextPart or substantial content
            text_idx = candidate.find('text="')
            if text_idx > 0:
                final_text = candidate[text_idx:]

# If still not found, try to extract all readable text
if not final_text:
    lines = content.split('\n')
    readable = []
    skip_markers = ['TurnBegin(', 'StepBegin(', 'ThinkPart(', 'ToolCall(', 
                   'ToolResult(', 'StatusUpdate(', 'FunctionBody(']
    for line in lines:
        if any(m in line for m in skip_markers):
            continue
        if line.strip().startswith(("type=", "tool_call_id=", "return_value=", 
                                   "is_error=", "encrypted=", "extras=")):
            continue
        readable.append(line)
    final_text = '\n'.join(readable)

# Clean up escape sequences
final_text = final_text.replace('\\"', '"').replace("\\'", "'")

with open(output_file, 'w', encoding='utf-8') as f:
    f.write("# Deep Search Report\n\n")
    f.write(f"**Query:** {sys.argv[3] if len(sys.argv) > 3 else 'N/A'}\n")
    f.write(f"**Date:** {sys.argv[4] if len(sys.argv) > 4 else 'N/A'}\n\n")
    f.write("---\n\n")
    f.write(final_text)

print(f"Extracted {len(final_text)} characters")
PYEOF

# Append footer
COMPLETED_AT="$(date -Iseconds)"
echo -e "\n\n---\n\n_Search completed: ${COMPLETED_AT}_" >> "$OUTPUT"

LINES=$(wc -l < "$OUTPUT" 2>/dev/null || echo 0)
FILE_SIZE=$(stat -c%s "$OUTPUT" 2>/dev/null || echo 0)

# Calculate duration
START_TS=$(date -d "$STARTED_AT" +%s 2>/dev/null || date +%s)
END_TS=$(date +%s)
ELAPSED=$(( END_TS - START_TS ))
MINS=$(( ELAPSED / 60 ))
SECS=$(( ELAPSED % 60 ))
DURATION="${MINS}m${SECS}s"

# Status
if [[ "$EXIT_CODE" == "0" ]]; then
  STATUS="done"; STATUS_EMOJI="✅"
elif [[ "$EXIT_CODE" == "124" ]]; then
  STATUS="timeout"; STATUS_EMOJI="⏱"
else
  STATUS="failed"; STATUS_EMOJI="❌"
fi

echo "[kimi-deep-search] Done (${DURATION}, ${STATUS}, ${LINES} lines, ${FILE_SIZE} bytes)"

# Send Telegram notification
if [[ -n "$TELEGRAM_GROUP" ]] && [[ -x "$OPENCLAW_BIN" ]]; then
  SUMMARY=$(head -30 "$OUTPUT" | grep -v "^#" | grep -v "^\*\*" | grep -v "^---" | head -10 | head -c 500 || echo "Report generated")
  
  MSG="${STATUS_EMOJI} *Kimi Deep Search Complete*

🔍 *Query:* ${PROMPT}
⏱ *Duration:* ${DURATION}
📄 *Lines:* ${LINES} | *Size:* ${FILE_SIZE} bytes
📂 \`${OUTPUT}\`

📝 *Preview:*
${SUMMARY}"

  "$OPENCLAW_BIN" message send --channel telegram --target "$TELEGRAM_GROUP" --message "$MSG" 2>/dev/null || true
fi

exit $EXIT_CODE
