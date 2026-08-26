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

args=(
  --model "${MODEL_DIR}/${MODEL_FILE}"
  --gpu-layers "${GPU_LAYERS}"
  --ctx-size "${CONTEXT_SIZE}"
  --spec-type draft-mtp
  --spec-draft-model "${MODEL_DIR}/${MTP_FILE}"
  --spec-draft-ngl "${MTP_GPU_LAYERS}"
  --spec-draft-n-max "${MTP_DRAFT_N_MAX}"
  "${REASONING_ARGS[@]}"
)

exec "${LLAMA_DIR}/llama-cli" "${args[@]}"
