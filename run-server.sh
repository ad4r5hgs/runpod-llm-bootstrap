#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/config.env}"
source "$CONFIG_FILE"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/runtime.sh"

usage() {
  cat <<EOF_USAGE
Usage: ./run-server.sh [--foreground] [--session NAME]

  No flags (default): start llama-server inside a detached tmux session.
  --foreground: run in this terminal instead (for debugging).
  --session NAME: tmux session name (default: qwen, or \$TMUX_SESSION).

The server always binds 0.0.0.0 (public inside the Pod network, including the
RunPod HTTP proxy). LLAMA_API_KEY is therefore always required.
EOF_USAGE
}

FOREGROUND=0
SESSION_NAME="${TMUX_SESSION:-qwen}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --foreground) FOREGROUND=1; shift ;;
    --session) [[ $# -ge 2 ]] || { echo "ERROR: --session needs a name." >&2; exit 1; }
      SESSION_NAME="$2"; shift 2 ;;
    --session=*) SESSION_NAME="${1#--session=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1 (see --help)." >&2; exit 1 ;;
  esac
done
[[ -n "$SESSION_NAME" ]] || { echo "ERROR: tmux session name must not be empty." >&2; exit 1; }

REASONING_MODE="${REASONING_MODE:-auto}"
REASONING_BUDGET="${REASONING_BUDGET:-}"
MTP_DRAFT_N_MAX="${MTP_DRAFT_N_MAX:-3}"
MTP_DRAFT_P_MIN="${MTP_DRAFT_P_MIN:-}"
configure_llama_runtime
build_reasoning_args
build_performance_args
build_server_args
build_mtp_args

# This script always serves publicly so coding harnesses and the RunPod HTTP
# proxy can reach it. localhost-only is no longer an option here; use SSH
# port-forwarding plus the API key if you want tighter control. The key is
# mandatory because an unauthenticated public endpoint would be abused.
if [[ "${SERVER_HOST:-0.0.0.0}" != "0.0.0.0" ]]; then
  echo "NOTE: ignoring SERVER_HOST=${SERVER_HOST} from config; binding 0.0.0.0." >&2
fi
SERVER_HOST="0.0.0.0"
SERVER_PORT="${SERVER_PORT:-8080}"
SERVER_MODEL_ID="${SERVER_MODEL_ID:-qwen3.8-27b-philbert}"
if [[ -z "${LLAMA_API_KEY:-}" ]]; then
  echo "ERROR: LLAMA_API_KEY is required (server always binds 0.0.0.0)." >&2
  echo "Set LLAMA_API_KEY in config.env (and do not commit it)." >&2
  exit 1
fi

# Alias flag varies by build: newer --model-alias, older --alias,
# oldest neither (server still works, model id defaults to path).
SERVER_HELP="$("${LLAMA_DIR}/llama-server" --help 2>&1 || true)"

args=(
  --model "${MODEL_DIR}/${MODEL_FILE}"
  --gpu-layers "${GPU_LAYERS}"
  --ctx-size "${CONTEXT_SIZE}"
  "${MTP_ARGS[@]}"
  "${PERFORMANCE_ARGS[@]}"
  "${SERVER_RUNTIME_ARGS[@]}"
  "${REASONING_ARGS[@]}"
  --host "${SERVER_HOST}"
  --port "${SERVER_PORT}"
)

if grep -Fq -- '--model-alias' <<< "$SERVER_HELP"; then
  args+=(--model-alias "${SERVER_MODEL_ID}")
elif grep -Fq -- '--alias' <<< "$SERVER_HELP"; then
  args+=(--alias "${SERVER_MODEL_ID}")
fi

args+=(--api-key "${LLAMA_API_KEY}")

LLAMA_BIN="${LLAMA_DIR}/llama-server"
[[ -x "$LLAMA_BIN" ]] || { echo "ERROR: llama-server not found: $LLAMA_BIN" >&2; exit 1; }

if (( FOREGROUND == 1 )); then
  echo "Running in foreground on ${SERVER_HOST}:${SERVER_PORT} (Ctrl+C to stop)."
  exec "$LLAMA_BIN" "${args[@]}"
fi

command -v tmux >/dev/null 2>&1 || {
  echo "ERROR: tmux is required for default mode (use --foreground without tmux)." >&2
  exit 1
}

if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
  echo "ERROR: tmux session '${SESSION_NAME}' already exists." >&2
  echo "Use: tmux attach -t ${SESSION_NAME}  |  tmux capture-pane -p -t ${SESSION_NAME} | tail" >&2
  echo "Or stop it first: tmux kill-session -t ${SESSION_NAME}" >&2
  exit 1
fi

# Pass the library path explicitly: a running tmux server may not inherit it.
tmux new-session -d -s "$SESSION_NAME" \
  env LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" \
  "$LLAMA_BIN" "${args[@]}"

echo "Server starting in tmux session '${SESSION_NAME}' on ${SERVER_HOST}:${SERVER_PORT}."
echo "Watch logs:  tmux capture-pane -p -t ${SESSION_NAME} | tail -n 40"
echo "Attach:      tmux attach -t ${SESSION_NAME}   (detach with Ctrl+B then D)"
echo "Stop:        tmux kill-session -t ${SESSION_NAME}"
echo "Health:      curl localhost:${SERVER_PORT}/health"
echo "Foreground instead: ./run-server.sh --foreground"
