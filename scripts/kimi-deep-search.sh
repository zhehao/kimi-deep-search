#!/usr/bin/env bash
# Kimi Deep Search - OpenClaw wrapper
# Usage: /kimi-deep-search <query>

SKILL_DIR="${HOME}/.openclaw/workspace/skills/kimi-deep-search"
QUERY="$*"

if [[ -z "$QUERY" ]]; then
  echo "Usage: /kimi-deep-search <research query>"
  echo "Example: /kimi-deep-search NVIDIA Rubin Ultra 供应链分析"
  exit 1
fi

# Generate task name from query
TASK_NAME="kimi-$(date +%s)"
OUTPUT_FILE="${SKILL_DIR}/data/kimi-search-results/${TASK_NAME}.md"

# Detect chat ID from environment or use default
CHAT_ID="${OPENCLAW_CHAT_ID:-${TELEGRAM_CHAT_ID:-}}"

# Run search with auto-send
exec bash "${SKILL_DIR}/scripts/search.sh" \
  --prompt "$QUERY" \
  --task-name "$TASK_NAME" \
  --output "$OUTPUT_FILE" \
  --timeout 180 \
  --send-to-chat \
  --chat-id "$CHAT_ID"
