#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/config.env}"
source "$CONFIG_FILE"

exec "${LLAMA_DIR}/llama-cli" \
  --model "${MODEL_DIR}/${MODEL_FILE}" \
  --gpu-layers "${GPU_LAYERS}" \
  --ctx-size "${CONTEXT_SIZE}" \
  --spec-type draft-mtp \
  --spec-draft-model "${MODEL_DIR}/${MTP_FILE}" \
  --spec-draft-ngl "${MTP_GPU_LAYERS}" \
  --spec-draft-n-max "${MTP_DRAFT_N_MAX}" \
  --reasoning-effort "${REASONING_EFFORT}"
