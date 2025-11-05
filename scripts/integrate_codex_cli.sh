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

log_step "OpenAI Codex CLI Integration (hosted MCP)"
echo
echo "This script will:"
echo "  1) Use the hosted MCP Agent Mail endpoint (override with MCP_MAIL_URL if needed)."
echo "  2) Embed your provided bearer token into Codex CLI + project configs."
echo "  3) Run ensure_project/register_agent against the remote server."
echo
TARGET_DIR="${PROJECT_DIR:-}"
if [[ -z "${TARGET_DIR}" ]]; then TARGET_DIR="${ROOT_DIR}"; fi
if ! confirm "Proceed?"; then log_warn "Aborted."; exit 1; fi

cd "$ROOT_DIR"

_URL="$(resolve_mcp_mail_url)"
log_ok "Using MCP endpoint: ${_URL}"
_TOKEN="$(require_mcp_mail_token)"
if [[ "${SHOW_TOKEN:-0}" == "1" ]]; then
  log_warn "Bearer token: ${_TOKEN}"
fi

OUT_JSON="${TARGET_DIR}/codex.mcp.json"
backup_file "$OUT_JSON"
log_step "Writing ${OUT_JSON}"
write_atomic "$OUT_JSON" <<JSON
{
  "mcpServers": {
    "mcp-agent-mail": {
      "type": "streamable-http",
      "url": "${_URL}",
      "timeout": 60,
      "disabled": false,
      "alwaysAllow": [
        "macro_start_session",
        "file_reservation_paths",
        "fetch_inbox",
        "release_file_reservations",
        "acknowledge_message",
        "send_message",
        "mark_message_read"
      ],
      "headers": {
        "Authorization": "Bearer ${_TOKEN}"
      }
    }
  }
}
JSON
json_validate "$OUT_JSON" || true
set_secure_file "$OUT_JSON"

log_step "Registering MCP server in Codex CLI config"
# Update user-level ~/.codex/config.toml
CODEX_DIR="${HOME}/.codex"
mkdir -p "$CODEX_DIR"
USER_TOML="${CODEX_DIR}/config.toml"
backup_file "$USER_TOML"
{
  echo ""
  echo "# MCP servers configuration (mcp-agent-mail)"
  echo "[mcp_servers.mcp_agent_mail]"
  echo "transport = \"streamable_http\""
  echo "url = \"${_URL}\""
  echo ""
  echo "[mcp_servers.mcp_agent_mail.http_headers]"
  echo "Authorization = \"Bearer ${_TOKEN}\""
} >> "$USER_TOML"

# Also write project-local .codex/config.toml for portability
LOCAL_CODEX_DIR="${TARGET_DIR}/.codex"
mkdir -p "$LOCAL_CODEX_DIR"
LOCAL_TOML="${LOCAL_CODEX_DIR}/config.toml"

# Bug 2 fix: Backup before writing, use write_atomic
if [[ -f "$LOCAL_TOML" ]]; then
  backup_file "$LOCAL_TOML"
fi

write_atomic "$LOCAL_TOML" <<TOML
# Project-local Codex MCP configuration
[mcp_servers.mcp_agent_mail]
transport = "streamable_http"
url = "${_URL}"

[mcp_servers.mcp_agent_mail.http_headers]
Authorization = "Bearer ${_TOKEN}"
TOML

# Bug 1 fix: Ensure secure permissions
# Bug #5 fix: set_secure_file logs its own warning, no need to duplicate
set_secure_file "$LOCAL_TOML" || true

log_step "Bootstrapping project and agent on server"
_AUTH_ARGS=("-H" "Authorization: Bearer ${_TOKEN}")

# Bug 6 fix: Use json_escape_string to safely escape variables
# Issue #7 fix: Validate escaping succeeded
_HUMAN_KEY_ESCAPED=$(json_escape_string "${TARGET_DIR}") || { log_err "Failed to escape project path"; exit 1; }
_AGENT_ESCAPED=$(json_escape_string "${USER:-codex}") || { log_err "Failed to escape agent name"; exit 1; }

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
    -d "{\"jsonrpc\":\"2.0\",\"id\":\"2\",\"method\":\"tools/call\",\"params\":{\"name\":\"register_agent\",\"arguments\":{\"project_key\":${_HUMAN_KEY_ESCAPED},\"program\":\"codex-cli\",\"model\":\"gpt-5-codex\",\"name\":${_AGENT_ESCAPED},\"task_description\":\"setup\"}}}" \
    "${_URL}" >/dev/null 2>&1; then
  log_ok "Registered agent on server"
else
  log_warn "Failed to register agent (remote server unavailable?)"
fi

echo "Done."
