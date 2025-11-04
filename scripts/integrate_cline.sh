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

log_step "Cline Integration (HTTP MCP)"
echo
echo "This script will:"
echo "  1) Detect your MCP HTTP endpoint from settings."
echo "  2) Auto-generate a bearer token if missing and export it at runtime."
echo "  3) Create scripts/run_server_with_token.sh to start the server with the token."
echo "  4) Write a project-local cline.mcp.json you can import/configure in Cline."
echo "  5) Bootstrap ensure_project/register_agent on the remote server."
echo

TARGET_DIR="${PROJECT_DIR:-}"
if [[ -z "${TARGET_DIR}" ]]; then TARGET_DIR="${ROOT_DIR}"; fi
if ! confirm "Proceed?"; then log_warn "Aborted."; exit 1; fi

cd "$ROOT_DIR"

_MCP_URL_OVERRIDE="$(resolve_mcp_mail_url)"

log_step "Resolving HTTP endpoint from settings"
eval "$(uv run python - <<'PY'
from mcp_agent_mail.config import get_settings
s = get_settings()
print(f"export _HTTP_HOST='{s.http.host}'")
print(f"export _HTTP_PORT='{s.http.port}'")
print(f"export _HTTP_PATH='{s.http.path}'")
PY
)"

# Validate Python eval output
if [[ -z "${_HTTP_HOST}" || -z "${_HTTP_PORT}" || -z "${_HTTP_PATH}" ]]; then
  log_err "Failed to detect HTTP endpoint from settings (Python eval failed)"
  exit 1
fi

_URL="http://${_HTTP_HOST}:${_HTTP_PORT}${_HTTP_PATH}"
if [[ -n "${_MCP_URL_OVERRIDE}" ]]; then
  _URL="${_MCP_URL_OVERRIDE}"
fi
log_ok "Detected MCP HTTP endpoint: ${_URL}"

# Determine or generate bearer token
_TOKEN="${INTEGRATION_BEARER_TOKEN:-}"
if [[ -z "${_TOKEN}" ]]; then
  _TOKEN="$(require_mcp_mail_token)"
fi

# Write project-local Cline MCP config snippet
OUT_JSON="${TARGET_DIR}/cline.mcp.json"
backup_file "$OUT_JSON"
log_step "Writing ${OUT_JSON}"
AUTH_HEADER_LINE=$'      "headers": { "Authorization": "Bearer '"${_TOKEN}"$'" },'
write_atomic "$OUT_JSON" <<JSON
{
  "mcpServers": {
    "mcp-agent-mail": {
      "type": "streamable_http",
      "url": "${_URL}",
${AUTH_HEADER_LINE}
      "note": "Import or configure this server in Cline's MCP settings"
    }
  }
}
JSON
json_validate "$OUT_JSON" || true
set_secure_file "$OUT_JSON" || true

# Create run helper script
log_step "Creating run helper script"
mkdir -p scripts
RUN_HELPER="scripts/run_server_with_token.sh"
write_atomic "$RUN_HELPER" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${HTTP_BEARER_TOKEN:-}" ]]; then
  if [[ -f .env ]]; then
    HTTP_BEARER_TOKEN=$(grep -E '^HTTP_BEARER_TOKEN=' .env | sed -E 's/^HTTP_BEARER_TOKEN=//') || true
  fi
fi
if [[ -z "${HTTP_BEARER_TOKEN:-}" ]]; then
  if command -v uv >/dev/null 2>&1; then
    HTTP_BEARER_TOKEN=$(uv run python - <<'PY'
import secrets; print(secrets.token_hex(32))
PY
)
  else
    HTTP_BEARER_TOKEN="$(date +%s)_$(hostname)"
  fi
fi
export HTTP_BEARER_TOKEN

uv run python -m mcp_agent_mail.cli serve-http "$@"
SH
set_secure_exec "$RUN_HELPER" || true

# Bootstrap ensure_project + register_agent (best-effort)
log_step "Bootstrapping project and agent on server"
_AUTH_ARGS=("-H" "Authorization: Bearer ${_TOKEN}")

_HUMAN_KEY_ESCAPED=$(json_escape_string "${TARGET_DIR}") || { log_err "Failed to escape project path"; exit 1; }
_AGENT_ESCAPED=$(json_escape_string "${USER:-cline}") || { log_err "Failed to escape agent name"; exit 1; }

if curl -fsS --connect-timeout 5 --max-time 10 --retry 0 -H "Content-Type: application/json" "${_AUTH_ARGS[@]}" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"tools/call\",\"params\":{\"name\":\"ensure_project\",\"arguments\":{\"human_key\":${_HUMAN_KEY_ESCAPED}}}}" \
    "${_URL}" >/dev/null 2>&1; then
  log_ok "Ensured project on server"
else
  log_warn "Failed to ensure project (remote server unavailable?)"
fi

if curl -fsS --connect-timeout 5 --max-time 10 --retry 0 -H "Content-Type: application/json" "${_AUTH_ARGS[@]}" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":\"2\",\"method\":\"tools/call\",\"params\":{\"name\":\"register_agent\",\"arguments\":{\"project_key\":${_HUMAN_KEY_ESCAPED},\"program\":\"cline\",\"model\":\"default\",\"name\":${_AGENT_ESCAPED},\"task_description\":\"setup\"}}}" \
    "${_URL}" >/dev/null 2>&1; then
  log_ok "Registered agent on server"
else
  log_warn "Failed to register agent (remote server unavailable?)"
fi

echo
log_ok "==> Done."
_print "A project-local MCP config was written to ${OUT_JSON}."
_print "Open Cline's MCP settings and add this server:"
_print "  - Type: http"
_print "  - URL: ${_URL}"
if [[ -n "${_TOKEN}" ]]; then
  _print "  - Header: Authorization: Bearer ${_TOKEN}"
else
  _print "  - Header: (optional on localhost if server allows)"
fi
_print "Then start the server with: ${RUN_HELPER}"
