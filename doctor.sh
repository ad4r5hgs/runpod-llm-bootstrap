#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/config.env}"
source "$CONFIG_FILE"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/runtime.sh"

REASONING_MODE="${REASONING_MODE:-auto}"
REASONING_BUDGET="${REASONING_BUDGET:-}"

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

check_gpu_target() {
  local gpu_name
  gpu_name="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1)"
  if [[ "${REQUIRE_A40:-false}" == "true" ]]; then
    [[ "$gpu_name" == *"A40" ]]
  else
    [[ -n "$gpu_name" ]]
  fi
}

check_llama_cuda() {
  configure_llama_runtime
  "${LLAMA_DIR}/llama-cli" --list-devices 2>&1 | grep -q 'CUDA0:'
}

check_llama_libraries() {
  configure_llama_runtime
  ! ldd "${LLAMA_DIR}/llama-cli" 2>&1 | grep -q 'not found'
}

check_reasoning_flags() {
  configure_llama_runtime
  build_reasoning_args
  local help_output
  help_output="$("${LLAMA_DIR}/llama-cli" --help 2>&1 || true)"
  grep -Fq -- '--reasoning' <<< "$help_output" || return 1
  if [[ -n "${REASONING_BUDGET:-}" ]]; then
    grep -Fq -- '--reasoning-budget' <<< "$help_output" || return 1
  fi
}

check_mtp_flags() {
  configure_llama_runtime
  build_mtp_args >/dev/null 2>&1 || return 1
  local help_output
  help_output="$("${LLAMA_DIR}/llama-cli" --help 2>&1 || true)"
  grep -Fq -- '--spec-type' <<< "$help_output" || return 1
  grep -Fq -- '--spec-draft-model' <<< "$help_output" || return 1
  grep -Fq -- '--spec-draft-n-max' <<< "$help_output" || return 1
}

check_mtp_pmin() {
  # Informational only: passes when no p-min is configured, or when the
  # binary supports it. b10182 does not list --spec-draft-p-min.
  if [[ -z "${MTP_DRAFT_P_MIN:-}" ]]; then
    return 0
  fi
  configure_llama_runtime
  local help_output
  help_output="$("${LLAMA_DIR}/llama-cli" --help 2>&1 || true)"
  grep -Fq -- '--spec-draft-p-min' <<< "$help_output"
}

check_performance_flags() {
  configure_llama_runtime
  local help_output
  help_output="$("${LLAMA_DIR}/llama-server" --help 2>&1 || true)"
  grep -Eq -- '--flash-attn' <<< "$help_output" &&
    grep -Eq -- '--cache-type-k' <<< "$help_output" &&
    grep -Eq -- '--cache-type-v' <<< "$help_output" &&
    grep -Eq -- '--batch-size' <<< "$help_output" &&
    grep -Eq -- '--ubatch-size' <<< "$help_output" &&
    grep -Eq -- '--parallel' <<< "$help_output"
}

check_disk_headroom() {
  local avail_kb
  avail_kb="$(df -Pk "${MODEL_DIR}" | awk 'NR==2 {print $4}')"
  [[ "$avail_kb" =~ ^[0-9]+$ ]] && (( avail_kb >= 5 * 1024 * 1024 ))
}

check 'nvidia-smi available' command -v nvidia-smi
check 'target GPU visible in NVIDIA-SMI' check_gpu_target
check 'llama-cli exists' test -x "${LLAMA_DIR}/llama-cli"
check 'llama-server exists' test -x "${LLAMA_DIR}/llama-server"
check 'llama.cpp shared libraries resolve' check_llama_libraries
check 'llama.cpp sees CUDA' check_llama_cuda
check 'reasoning flags supported' check_reasoning_flags
check 'native MTP flags supported' check_mtp_flags
check 'MTP p-min supported (only if MTP_DRAFT_P_MIN is set)' check_mtp_pmin
check 'long-context performance flags supported' check_performance_flags
check 'main model exists' test -f "${MODEL_DIR}/${MODEL_FILE}"
check 'MTP model exists' test -f "${MODEL_DIR}/${MTP_FILE}"
check 'disk headroom >= 5 GiB' check_disk_headroom

configure_llama_runtime >/dev/null 2>&1 || true
"${LLAMA_DIR}/llama-cli" --version || true

echo
nvidia-smi --query-gpu=name,memory.total,memory.used,memory.free,driver_version --format=csv
printf '\nModel files:\n'
if [[ -f "${MODEL_DIR}/${MODEL_FILE}" && -f "${MODEL_DIR}/${MTP_FILE}" ]]; then
  ls -lh "${MODEL_DIR}/${MODEL_FILE}" "${MODEL_DIR}/${MTP_FILE}"
else
  echo "Model files are not all present."
fi
printf '\nConfig: llama.cpp=%s, context=%s, MTP n-max=%s%s, parallel=%s, KV=%s/%s, flash-attn=%s, reasoning=%s\n' \
  "${LLAMA_CPP_TAG:-unknown}" "${CONTEXT_SIZE:-?}" "${MTP_DRAFT_N_MAX:-3}" \
  "${MTP_DRAFT_P_MIN:+ (p-min ${MTP_DRAFT_P_MIN})}" \
  "${SERVER_PARALLEL:-1}" "${CACHE_TYPE_K:-f16}" "${CACHE_TYPE_V:-f16}" \
  "${FLASH_ATTN:-auto}" "${REASONING_MODE:-auto}${REASONING_BUDGET:+ (budget ${REASONING_BUDGET})}"

exit "$fail"
