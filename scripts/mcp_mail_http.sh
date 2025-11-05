#!/usr/bin/env bash
set -euo pipefail

URL="${MCP_MAIL_URL:-https://mcp.gauntlit.ai/mcp/}"
AUTH=()
_TOKEN="${MCP_MAIL_BEARER_TOKEN:-${HTTP_BEARER_TOKEN:-}}"
if [[ -n "${_TOKEN}" ]]; then
  AUTH=( -H "Authorization: Bearer ${_TOKEN}" )
fi

METHOD="${1:-}"
shift || true

usage() {
  echo "Usage:" >&2
  echo "  $0 resources/read '<resource-uri>'" >&2
  echo "  $0 tools/call <name> '<arguments-json>'" >&2
  echo "  # Back-compat: $0 tools/call '<params-json>'" >&2
}

if [[ -z "${METHOD}" ]]; then
  usage; exit 2
fi

case "${METHOD}" in
  resources/read)
    URI="${1:-}"; [[ -z "${URI}" ]] && { echo "Missing resource URI" >&2; exit 2; }
    jq -n --arg uri "$URI" '{jsonrpc:"2.0", id:"1", method:"resources/read", params:{uri:$uri}}' \
      | curl -sS -X POST "$URL" -H 'content-type: application/json' "${AUTH[@]}" --data-binary @-
    ;;
  tools/call)
    if [[ $# -ge 2 ]]; then
      NAME="${1}"; shift
      ARGS_JSON="${1}"; shift || true
      jq -n --arg name "$NAME" --argjson arguments "$ARGS_JSON" '{jsonrpc:"2.0", id:"1", method:"tools/call", params:{name:$name, arguments:$arguments}}' \
        | curl -sS -X POST "$URL" -H 'content-type: application/json' "${AUTH[@]}" --data-binary @-
    elif [[ $# -eq 1 ]]; then
      PARAMS_JSON="${1}"; shift || true
      jq -n --argjson params "$PARAMS_JSON" '{jsonrpc:"2.0", id:"1", method:"tools/call", params:$params}' \
        | curl -sS -X POST "$URL" -H 'content-type: application/json' "${AUTH[@]}" --data-binary @-
    else
      usage; exit 2
    fi
    ;;
  *)
    echo "Unsupported method: ${METHOD}" >&2; exit 2;
    ;;
esac
