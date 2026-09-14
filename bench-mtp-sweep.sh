#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Step 1 + Step 2 speed sweep in plain language:
# Step 1 = helper guessing depth (MTP n-max 1,2,3,4 plus smart 16 + p-min 0.8).
# Step 2 = scratch-paper size (KV cache pairs, default q4_0 vs q8_0).
# Everything keeps your full 262K context allocation. Reasoning is off for the
# sweep because it is the fastest, most repeatable setting for comparing speed.
#
# Order to run on the Pod:
#   cp config.env.example config.env   # once
#   ./setup.sh                         # once (downloads model + engine)
#   ./doctor.sh                        # once (quick health check)
#   ./bench-mtp-sweep.sh               # this sweep (takes a while, one run per combo)
#
# Tune the combos in config.env without editing this script:
#   SWEEP_N_MAX_LIST, SWEEP_EXTRA_N_MAX, SWEEP_EXTRA_P_MIN,
#   SWEEP_KV_PAIRS, SWEEP_N_PREDICT, SWEEP_PROMPT

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/config.env}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: $CONFIG_FILE not found. Copy config.env.example to config.env first." >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/runtime.sh"

die() { echo "ERROR: $*" >&2; exit 1; }

# Required keys fail fast with a clear message instead of set -u crashes.
: "${GPU_LAYERS:?GPU_LAYERS must be set in config.env}"
: "${MTP_GPU_LAYERS:?MTP_GPU_LAYERS must be set in config.env}"
: "${CONTEXT_SIZE:?CONTEXT_SIZE must be set in config.env}"
: "${FLASH_ATTN:?FLASH_ATTN must be set in config.env}"
: "${BATCH_SIZE:?BATCH_SIZE must be set in config.env}"
: "${UBATCH_SIZE:?UBATCH_SIZE must be set in config.env}"
: "${MODEL_DIR:?MODEL_DIR must be set in config.env}"
: "${MODEL_FILE:?MODEL_FILE must be set in config.env}"
: "${MTP_FILE:?MTP_FILE must be set in config.env}"

SWEEP_N_MAX_LIST="${SWEEP_N_MAX_LIST:-1 2 3 4}"
SWEEP_EXTRA_N_MAX="${SWEEP_EXTRA_N_MAX:-16}"
SWEEP_EXTRA_P_MIN="${SWEEP_EXTRA_P_MIN:-0.8}"
SWEEP_KV_PAIRS="${SWEEP_KV_PAIRS:-q4_0:q4_0 q8_0:q8_0}"
SWEEP_N_PREDICT="${SWEEP_N_PREDICT:-128}"
SWEEP_PROMPT="${SWEEP_PROMPT:-Explain in simple terms what a crash-safe file save is. Keep the answer short.}"

[[ "$SWEEP_N_PREDICT" =~ ^[1-9][0-9]*$ ]] || die "SWEEP_N_PREDICT must be a positive integer."
[[ "$SWEEP_EXTRA_N_MAX" =~ ^[1-9][0-9]*$ ]] || die "SWEEP_EXTRA_N_MAX must be a positive integer."
[[ "$SWEEP_EXTRA_P_MIN" =~ ^(0(\.[0-9]+)?|1(\.0*)?)$ ]] || die "SWEEP_EXTRA_P_MIN must be between 0 and 1."

configure_llama_runtime
build_performance_args >/dev/null || die "Invalid performance configuration in config.env."

[[ -x "${LLAMA_DIR}/llama-cli" ]] || die "llama-cli not found: ${LLAMA_DIR}/llama-cli"
[[ -f "${MODEL_DIR}/${MODEL_FILE}" ]] || die "Main model missing: ${MODEL_DIR}/${MODEL_FILE}"
[[ -f "${MODEL_DIR}/${MTP_FILE}" ]] || die "MTP model missing: ${MODEL_DIR}/${MTP_FILE}"

HELP_OUTPUT="$("${LLAMA_DIR}/llama-cli" --help 2>&1 || true)"
grep -Fq -- '--spec-type' <<< "$HELP_OUTPUT" || die "This llama.cpp build does not support --spec-type."
grep -Fq -- '--spec-draft-n-max' <<< "$HELP_OUTPUT" || die "This llama.cpp build does not support --spec-draft-n-max."
HAS_PMIN=0
if grep -Fq -- '--spec-draft-p-min' <<< "$HELP_OUTPUT"; then
  HAS_PMIN=1
fi

OUT_DIR="${SWEEP_OUT_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/qwen-sweep-XXXXXX")}"
mkdir -p "$OUT_DIR"
SUMMARY_CSV="${OUT_DIR}/summary.csv"
echo "combo,k_cache,v_cache,mtp_n_max,mtp_p_min,prompt_ts,gen_ts,accept,log" > "$SUMMARY_CSV"

extract_timing() {
  local log="$1" pline gline prompt_ts gen_ts accept
  pline="$(grep -Eo '\[ Prompt:[^]]*\]' "$log" | tail -n1 || true)"
  gline="$(grep -Eo '\[ Generation:[^]]*\]' "$log" | tail -n1 || true)"
  # Fallback for builds that print a single combined line.
  if [[ -z "$gline" ]]; then
    gline="$(grep -Eo '\[ Prompt:[^]]*\]' "$log" | tail -n1 || true)"
  fi
  prompt_ts="$(sed -nE 's/.*Prompt:[[:space:]]*([0-9]+(\.[0-9]+)?).*/\1/p' <<< "$pline" | tail -n1)"
  gen_ts="$(sed -nE 's/.*Generation:[[:space:]]*([0-9]+(\.[0-9]+)?).*/\1/p' <<< "$gline" | tail -n1)"
  accept="$(grep -Eoi 'accept[^,]*' "$log" | tail -n1 || true)"
  printf '%s|%s|%s' "${prompt_ts:-?}" "${gen_ts:-?}" "${accept:-n/a}"
}

run_combo() {
  local label="$1" k_cache="$2" v_cache="$3" n_max="$4" p_min="$5" mtp_off="$6"
  local safe log output rc timing prompt_ts gen_ts accept
  safe="$(tr -c 'A-Za-z0-9_.-' '_' <<< "$label")"
  log="${OUT_DIR}/${safe}.log"

  local args=(
    --model "${MODEL_DIR}/${MODEL_FILE}"
    --gpu-layers "${GPU_LAYERS}"
    --ctx-size "${CONTEXT_SIZE}"
    --flash-attn "${FLASH_ATTN}"
    --cache-type-k "$k_cache"
    --cache-type-v "$v_cache"
    --batch-size "${BATCH_SIZE}"
    --ubatch-size "${UBATCH_SIZE}"
    --reasoning off
    --no-conversation
    --n-predict "$SWEEP_N_PREDICT"
    --prompt "$SWEEP_PROMPT"
  )
  if [[ "$mtp_off" != "1" ]]; then
    args+=(
      --spec-type draft-mtp
      --spec-draft-model "${MODEL_DIR}/${MTP_FILE}"
      --spec-draft-ngl "${MTP_GPU_LAYERS}"
      --spec-draft-n-max "$n_max"
    )
    [[ -n "$p_min" ]] && args+=(--spec-draft-p-min "$p_min")
  fi

  printf '\n=== %s ===\n' "$label"
  printf 'KV=%s/%s, MTP=%s, log=%s\n' "$k_cache" "$v_cache" \
    "$([ "$mtp_off" = "1" ] && echo "off" || echo "n-max=${n_max}${p_min:+ p-min=${p_min}}")" "$log"

  if [[ "$k_cache" != "$v_cache" ]]; then
    echo "NOTE: K and V differ; on Ampere CUDA this can fall back to slow CPU. Prefer matching pairs."
  fi

  set +e
  output="$("${LLAMA_DIR}/llama-cli" "${args[@]}" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$output" | tee "$log" >/dev/null
  printf '%s\n' "$output" | tail -n 20

  if (( rc != 0 )); then
    echo "RESULT: FAIL (exit $rc). See $log"
    echo "${label},${k_cache},${v_cache},${n_max},${p_min},FAIL,FAIL,FAIL,${log}" >> "$SUMMARY_CSV"
    return 0
  fi

  IFS='|' read -r prompt_ts gen_ts accept <<< "$(extract_timing "$log")"
  echo "RESULT: prompt ${prompt_ts} t/s, generation ${gen_ts} t/s, ${accept}"
  echo "${label},${k_cache},${v_cache},${n_max},${p_min},${prompt_ts},${gen_ts},\"${accept}\",${log}" >> "$SUMMARY_CSV"
}

printf 'Qwen speed sweep (full 262K allocation kept)\n'
printf 'Context: %s | GPU layers: %s | draft layers: %s\n' "$CONTEXT_SIZE" "$GPU_LAYERS" "$MTP_GPU_LAYERS"
printf 'Batch: %s/%s | Flash: %s | Predict per run: %s tokens\n' "$BATCH_SIZE" "$UBATCH_SIZE" "$FLASH_ATTN" "$SWEEP_N_PREDICT"
printf 'KV pairs: %s\n' "$SWEEP_KV_PAIRS"
printf 'N_MAX list: %s\n' "$SWEEP_N_MAX_LIST"
if (( HAS_PMIN == 1 )); then
  printf 'Smart combo: n-max=%s p-min=%s (supported by this build)\n' "$SWEEP_EXTRA_N_MAX" "$SWEEP_EXTRA_P_MIN"
else
  printf 'Smart combo skipped: this build does not list --spec-draft-p-min (older b10182). N_MAX sweep still runs.\n'
fi
printf 'Logs: %s\n' "$OUT_DIR"

# The outer IFS excludes spaces, so override it to split the space-separated lists.
OLD_IFS="$IFS"
IFS=$' \t\n' read -r -a KV_ARRAY <<< "$SWEEP_KV_PAIRS"
IFS=$' \t\n' read -r -a NMAX_ARRAY <<< "$SWEEP_N_MAX_LIST"
IFS="$OLD_IFS"

(( ${#KV_ARRAY[@]} > 0 )) || die "SWEEP_KV_PAIRS is empty."
(( ${#NMAX_ARRAY[@]} > 0 )) || die "SWEEP_N_MAX_LIST is empty."
for n_max in "${NMAX_ARRAY[@]}"; do
  [[ "$n_max" =~ ^[1-9][0-9]*$ ]] || die "Bad SWEEP_N_MAX_LIST entry: $n_max (want positive integer)."
done

for kv in "${KV_ARRAY[@]}"; do
  k_cache="${kv%%:*}"
  v_cache="${kv##*:}"
  [[ -n "$k_cache" && -n "$v_cache" ]] || die "Bad SWEEP_KV_PAIRS entry: $kv (want K:V)."
  for n_max in "${NMAX_ARRAY[@]}"; do
    run_combo "kv-${k_cache}-${v_cache}_nmax-${n_max}" "$k_cache" "$v_cache" "$n_max" "" "0"
  done
  if (( HAS_PMIN == 1 )); then
    run_combo "kv-${k_cache}-${v_cache}_nmax-${SWEEP_EXTRA_N_MAX}-pmin-${SWEEP_EXTRA_P_MIN}" \
      "$k_cache" "$v_cache" "$SWEEP_EXTRA_N_MAX" "$SWEEP_EXTRA_P_MIN" "0"
  fi
  run_combo "kv-${k_cache}-${v_cache}_mtp-off" "$k_cache" "$v_cache" "" "" "1"
done

printf '\n--- Summary (higher Generation t/s wins) ---\n'
column -s, -t "$SUMMARY_CSV" 2>/dev/null || cat "$SUMMARY_CSV"
printf '\nFull logs in: %s\n' "$OUT_DIR"
printf 'Next: keep the winning KV + N_MAX in config.env (MTP_DRAFT_N_MAX, MTP_DRAFT_P_MIN, CACHE_TYPE_K/V), then re-run ./doctor.sh and ./test-xhigh-thinking.sh.\n'
