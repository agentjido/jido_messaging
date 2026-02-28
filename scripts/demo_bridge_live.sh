#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f ".env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required env var: $name" >&2
    return 1
  fi
}

require_env TELEGRAM_BOT_TOKEN
require_env DISCORD_BOT_TOKEN
require_env TELEGRAM_CHAT_ID
require_env DISCORD_CHANNEL_ID

echo "Starting live bridge demo with topology config/demo.topology.live.yaml"
echo "Telegram chat: ${TELEGRAM_CHAT_ID}"
echo "Discord channel: ${DISCORD_CHANNEL_ID}"
echo "Press Ctrl+C twice to stop."

exec elixir scripts/demo_bridge_live.exs
