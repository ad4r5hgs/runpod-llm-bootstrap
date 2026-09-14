#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/config.env}"
source "$CONFIG_FILE"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/runtime.sh"

REASONING_MODE="${REASONING_MODE:-auto}"
REASONING_BUDGET="${REASONING_BUDGET:-}"
MTP_DRAFT_N_MAX="${MTP_DRAFT_N_MAX:-3}"
MTP_DRAFT_P_MIN="${MTP_DRAFT_P_MIN:-}"
configure_llama_runtime
build_reasoning_args
build_performance_args
build_server_args
build_mtp_args

SERVER_MODEL_ID="${SERVER_MODEL_ID:-qwen3.8-27b-philbert}"
SERVER_HOST="${SERVER_HOST:-127.0.0.1}"
SERVER_PORT="${SERVER_PORT:-8080}"

if [[ "${SERVER_HOST}" != "127.0.0.1" && -z "${LLAMA_API_KEY:-}" ]]; then
  echo "ERROR: Refusing to bind llama-server to ${SERVER_HOST} without LLAMA_API_KEY." >&2
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

if [[ -n "${LLAMA_API_KEY:-}" ]]; then
  args+=(--api-key "${LLAMA_API_KEY}")
fi

exec "${LLAMA_DIR}/llama-server" "${args[@]}"
