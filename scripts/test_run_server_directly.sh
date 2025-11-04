#!/usr/bin/env bash
# Test running server directly vs via script to see if Rich output differs

set -euo pipefail

if [[ -z "${HTTP_BEARER_TOKEN:-}" ]]; then
  if [[ -f .env ]]; then
    HTTP_BEARER_TOKEN=$(grep -E '^HTTP_BEARER_TOKEN=' .env | sed -E 's/^HTTP_BEARER_TOKEN=//') || true
  fi
fi
if [[ -z "${HTTP_BEARER_TOKEN:-}" ]]; then
  echo "Set HTTP_BEARER_TOKEN (or create it in .env) before running this script." >&2
  exit 1
fi
export HTTP_BEARER_TOKEN

echo "========================================"
echo "Running server with direct Python call"
echo "========================================"
echo ""
echo "Command: python -m mcp_agent_mail.cli serve-http"
echo ""

cd /data/projects/mcp_agent_mail
python -m mcp_agent_mail.cli serve-http --host 127.0.0.1 --port 13701
