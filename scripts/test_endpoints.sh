#!/usr/bin/env bash
set -euo pipefail

# Scripted integration tests for HTTP endpoints using curl.
# Defaults to the hosted MCP endpoint but can be overridden via BASE_URL/MCP_MAIL_URL.

BASE_URL=${BASE_URL:-${MCP_MAIL_URL:-https://mcp.gauntlit.ai/mcp/}}
BEARER_TOKEN=${MCP_MAIL_BEARER_TOKEN:-${HTTP_BEARER_TOKEN:-}}
if [[ -z "${BEARER_TOKEN}" ]]; then
  echo "Set MCP_MAIL_BEARER_TOKEN (or HTTP_BEARER_TOKEN) before running this script." >&2
  exit 1
fi

call_tools() {
  local name=$1; shift
  local args_json=$1; shift || true
  curl -sS -X POST "$BASE_URL" \
    -H 'content-type: application/json' \
    -H "Authorization: Bearer ${BEARER_TOKEN}" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"tools/call\",\"params\":{\"name\":\"$name\",\"arguments\":$args_json}}"
}

read_resource() {
  local uri=$1; shift
  curl -sS -X POST "$BASE_URL" \
    -H 'content-type: application/json' \
    -H "Authorization: Bearer ${BEARER_TOKEN}" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":\"2\",\"method\":\"resources/read\",\"params\":{\"uri\":\"$uri\"}}"
}

echo "[1/4] Health check"
call_tools health_check '{}'
echo

echo "[2/4] Ensure project"
call_tools ensure_project '{"human_key":"/tmp/demo-project"}'
echo

echo "[3/4] Register agent"
call_tools register_agent '{"project_key":"/tmp/demo-project","program":"demo","model":"gpt-foo"}'
echo

echo "[4/4] Environment resource"
read_resource 'resource://config/environment'
echo
