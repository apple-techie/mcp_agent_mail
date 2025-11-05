#!/usr/bin/env bash
set -euo pipefail

# Source shared helpers
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
if [[ -f "${ROOT_DIR}/scripts/lib.sh" ]]; then
  # shellcheck disable=SC1090
  . "${ROOT_DIR}/scripts/lib.sh"
else
  echo "FATAL: scripts/lib.sh not found" >&2
  exit 1
fi
init_colors
setup_traps
parse_common_flags "$@"
require_cmd uv
require_cmd curl

log_step "Cursor Integration (hosted MCP)"
echo
echo "This script will:"
echo "  1) Use the hosted MCP Agent Mail endpoint (override via MCP_MAIL_URL as needed)."
echo "  2) Embed your bearer token into Cursor MCP configs."
echo "  3) Run ensure_project/register_agent remotely."
echo
TARGET_DIR="${PROJECT_DIR:-}"
if [[ -z "${TARGET_DIR}" ]]; then TARGET_DIR="${ROOT_DIR}"; fi
if ! confirm "Proceed?"; then log_warn "Aborted."; exit 1; fi

cd "$ROOT_DIR"

_URL="$(resolve_mcp_mail_url)"
_TOKEN="$(require_mcp_mail_token)"
if [[ "${SHOW_TOKEN:-0}" == "1" ]]; then
  log_warn "Bearer token: ${_TOKEN}"
fi

AUTH_HEADER_LINE=$'        "Authorization": "Bearer '"${_TOKEN}"$'"'
OUT_JSON="${TARGET_DIR}/cursor.mcp.json"
backup_file "$OUT_JSON"
write_atomic "$OUT_JSON" <<JSON
{
  "mcpServers": {
    "mcp-agent-mail": {
      "type": "streamable_http",
      "url": "${_URL}",
      "headers": {
${AUTH_HEADER_LINE}
      }
    }
  }
}
JSON
json_validate "$OUT_JSON" || true
set_secure_file "$OUT_JSON"

echo "Wrote ${OUT_JSON}. Configure in Cursor."
echo "==> Installing user-level Cursor MCP config (best-effort)"
HOME_CURSOR_DIR="${HOME}/.cursor"
mkdir -p "$HOME_CURSOR_DIR"
HOME_CURSOR_JSON="${HOME_CURSOR_DIR}/mcp.json"

# Bug 2 fix: Backup before writing, use write_atomic
if [[ -f "$HOME_CURSOR_JSON" ]]; then
  backup_file "$HOME_CURSOR_JSON"
fi

write_atomic "$HOME_CURSOR_JSON" <<JSON
{
  "mcpServers": {
    "mcp-agent-mail": {
      "type": "streamable_http",
      "url": "${_URL}",
      "headers": {
        "Authorization": "Bearer ${_TOKEN}"
      }
    }
  }
}
JSON

# Bug 1 fix: Ensure secure permissions
# Bug #5 fix: set_secure_file logs its own warning, no need to duplicate
set_secure_file "$HOME_CURSOR_JSON" || true

log_step "Bootstrapping project and agent on server"
_AUTH_ARGS=("-H" "Authorization: Bearer ${_TOKEN}")

# Bug 6 fix: Use json_escape_string to safely escape variables
# Issue #7 fix: Validate escaping succeeded
_HUMAN_KEY_ESCAPED=$(json_escape_string "${TARGET_DIR}") || { log_err "Failed to escape project path"; exit 1; }
_AGENT_ESCAPED=$(json_escape_string "${USER:-cursor}") || { log_err "Failed to escape agent name"; exit 1; }

# ensure_project - Bug 16 fix: add logging
if curl -fsS --connect-timeout 5 --max-time 10 --retry 0 -H "Content-Type: application/json" "${_AUTH_ARGS[@]}" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"tools/call\",\"params\":{\"name\":\"ensure_project\",\"arguments\":{\"human_key\":${_HUMAN_KEY_ESCAPED}}}}" \
    "${_URL}" >/dev/null 2>&1; then
  log_ok "Ensured project on server"
else
  log_warn "Failed to ensure project (remote server unavailable?)"
fi

# register_agent - Bug 16 fix: add logging
if curl -fsS --connect-timeout 5 --max-time 10 --retry 0 -H "Content-Type: application/json" "${_AUTH_ARGS[@]}" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":\"2\",\"method\":\"tools/call\",\"params\":{\"name\":\"register_agent\",\"arguments\":{\"project_key\":${_HUMAN_KEY_ESCAPED},\"program\":\"cursor\",\"model\":\"cursor\",\"name\":${_AGENT_ESCAPED},\"task_description\":\"setup\"}}}" \
    "${_URL}" >/dev/null 2>&1; then
  log_ok "Registered agent on server"
else
  log_warn "Failed to register agent (remote server unavailable?)"
fi
