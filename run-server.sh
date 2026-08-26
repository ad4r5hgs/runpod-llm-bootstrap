#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/config.env}"
source "$CONFIG_FILE"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/runtime.sh"

REASONING_MODE="${REASONING_MODE:-auto}"
REASONING_BUDGET="${REASONING_BUDGET:-}"
configure_llama_runtime
build_reasoning_args

if [[ "${SERVER_HOST}" != "127.0.0.1" && -z "${LLAMA_API_KEY}" ]]; then
  echo "ERROR: Refusing to bind llama-server to ${SERVER_HOST} without LLAMA_API_KEY." >&2
  echo "Set LLAMA_API_KEY in config.env (and do not commit it)." >&2
  exit 1
fi

args=(
  --model "${MODEL_DIR}/${MODEL_FILE}"
  --gpu-layers "${GPU_LAYERS}"
  --ctx-size "${CONTEXT_SIZE}"
  --spec-type draft-mtp
  --spec-draft-model "${MODEL_DIR}/${MTP_FILE}"
  --spec-draft-ngl "${MTP_GPU_LAYERS}"
  --spec-draft-n-max "${MTP_DRAFT_N_MAX}"
  "${REASONING_ARGS[@]}"
  --host "${SERVER_HOST}"
  --port "${SERVER_PORT}"
  --model-alias "${SERVER_MODEL_ID}"
)

if [[ -n "${LLAMA_API_KEY}" ]]; then
  args+=(--api-key "${LLAMA_API_KEY}")
fi

exec "${LLAMA_DIR}/llama-server" "${args[@]}"
