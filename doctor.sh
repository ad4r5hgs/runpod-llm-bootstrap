#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/config.env}"
source "$CONFIG_FILE"

fail=0
check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf 'PASS  %s\n' "$name"
  else
    printf 'FAIL  %s\n' "$name"
    fail=1
  fi
}

check 'nvidia-smi available' command -v nvidia-smi
check 'A40 visible in NVIDIA-SMI' bash -c 'nvidia-smi --query-gpu=name --format=csv,noheader | grep -q A40'
check 'llama-cli exists' test -x "${LLAMA_DIR}/llama-cli"
check 'llama-server exists' test -x "${LLAMA_DIR}/llama-server"
check 'llama.cpp sees CUDA' bash -c '"${LLAMA_DIR}/llama-cli" --list-devices 2>&1 | grep -q CUDA0:'
check 'main model exists' test -f "${MODEL_DIR}/${MODEL_FILE}"
check 'MTP model exists' test -f "${MODEL_DIR}/${MTP_FILE}"
check 'disk headroom >= 5 GiB' bash -c 'avail_kb=$(df -Pk "${MODEL_DIR}" | awk "NR==2{print \\$4}"); ((avail_kb >= 5*1024*1024))'

"${LLAMA_DIR}/llama-cli" --version || true

echo
nvidia-smi --query-gpu=name,memory.total,memory.used,memory.free,driver_version --format=csv
printf '\nModel files:\n'
ls -lh "${MODEL_DIR}/${MODEL_FILE}" "${MODEL_DIR}/${MTP_FILE}"
printf '\nConfig: context=%s, MTP n-max=%s, reasoning=%s\n' "$CONTEXT_SIZE" "$MTP_DRAFT_N_MAX" "$REASONING_EFFORT"

exit "$fail"
