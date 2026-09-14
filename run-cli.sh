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
build_mtp_args

args=(
  --model "${MODEL_DIR}/${MODEL_FILE}"
  --gpu-layers "${GPU_LAYERS}"
  --ctx-size "${CONTEXT_SIZE}"
  "${MTP_ARGS[@]}"
  "${PERFORMANCE_ARGS[@]}"
  "${REASONING_ARGS[@]}"
)

exec "${LLAMA_DIR}/llama-cli" "${args[@]}"
