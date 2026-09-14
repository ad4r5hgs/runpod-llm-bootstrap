#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

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

TEST_TARGET_WORDS="${TEST_TARGET_WORDS:-120}"
TEST_N_PREDICT="${TEST_N_PREDICT:-32768}"
TEST_REASONING_BUDGET="${TEST_REASONING_BUDGET:-32000}"
TEST_PROMPT="${TEST_PROMPT:-}"
MTP_DRAFT_N_MAX="${MTP_DRAFT_N_MAX:-3}"
MTP_DRAFT_P_MIN="${MTP_DRAFT_P_MIN:-}"

[[ "$TEST_TARGET_WORDS" =~ ^[1-9][0-9]*$ ]] || die "TEST_TARGET_WORDS must be a positive integer."
[[ "$TEST_N_PREDICT" =~ ^[1-9][0-9]*$ ]] || die "TEST_N_PREDICT must be a positive integer."
[[ "$TEST_REASONING_BUDGET" =~ ^[1-9][0-9]*$ ]] || die "TEST_REASONING_BUDGET must be a positive integer."
(( TEST_REASONING_BUDGET < TEST_N_PREDICT )) || die "TEST_REASONING_BUDGET must be smaller than TEST_N_PREDICT so the model has room for its final answer."

if [[ -z "$TEST_PROMPT" ]]; then
  TEST_PROMPT="Think deeply about this coding-design question: a command-line tool rewrites its JSON configuration file and can be interrupted at any point. Explain a crash-safe atomic-write strategy, including validation and recovery. After completing your reasoning, output only a final answer of exactly ${TEST_TARGET_WORDS} words."
fi

configure_llama_runtime
build_performance_args
build_mtp_args || die "Invalid MTP configuration."

[[ -x "${LLAMA_DIR}/llama-cli" ]] || die "llama-cli not found: ${LLAMA_DIR}/llama-cli"
help_output="$("${LLAMA_DIR}/llama-cli" --help 2>&1 || true)"
grep -Fq -- '--reasoning' <<< "$help_output" || die "Pinned llama.cpp build does not support --reasoning."
grep -Fq -- '--reasoning-budget' <<< "$help_output" || die "Pinned llama.cpp build does not support --reasoning-budget."
if [[ -n "${MTP_DRAFT_P_MIN:-}" ]]; then
  grep -Fq -- '--spec-draft-p-min' <<< "$help_output" || die "MTP_DRAFT_P_MIN is set but this llama.cpp build does not list --spec-draft-p-min. Leave it empty for b10182."
fi

# b10182 lacks --reasoning-effort. Its Qwen template's default effort is used
# with reasoning enabled; newer builds get the explicit xhigh selector.
reasoning_args=(--reasoning on --reasoning-budget "$TEST_REASONING_BUDGET")
reasoning_mode_note="template default (pinned build has no --reasoning-effort)"
if grep -Fq -- '--reasoning-effort' <<< "$help_output"; then
  reasoning_args+=(--reasoning-effort xhigh)
  reasoning_mode_note="explicit xhigh"
fi

args=(
  --model "${MODEL_DIR}/${MODEL_FILE}"
  --gpu-layers "${GPU_LAYERS}"
  --ctx-size "${CONTEXT_SIZE}"
  "${MTP_ARGS[@]}"
  "${PERFORMANCE_ARGS[@]}"
  "${reasoning_args[@]}"
  --no-conversation
  --n-predict "$TEST_N_PREDICT"
  --prompt "$TEST_PROMPT"
)

log_file="$(mktemp "${TMPDIR:-/tmp}/qwen-xhigh-thinking.XXXXXX.log")"

printf 'Qwen full-context xhigh-thinking test\n'
printf 'Context capacity: %s tokens\n' "$CONTEXT_SIZE"
printf 'MTP: draft-mtp, n-max=%s%s, target GPU layers=%s, draft GPU layers=%s\n' \
  "$MTP_DRAFT_N_MAX" "${MTP_DRAFT_P_MIN:+ (p-min ${MTP_DRAFT_P_MIN})}" "$GPU_LAYERS" "$MTP_GPU_LAYERS"
printf 'KV cache: K=%s, V=%s; Flash Attention=%s\n' \
  "$CACHE_TYPE_K" "$CACHE_TYPE_V" "$FLASH_ATTN"
printf 'Batching: batch=%s, ubatch=%s\n' "$BATCH_SIZE" "$UBATCH_SIZE"
printf 'Reasoning: %s; budget=%s tokens; generation cap=%s tokens\n' \
  "$reasoning_mode_note" "$TEST_REASONING_BUDGET" "$TEST_N_PREDICT"
printf 'Final-answer instruction: exactly %s words\n' "$TEST_TARGET_WORDS"
printf 'Transcript: %s\n\n' "$log_file"

"${LLAMA_DIR}/llama-cli" "${args[@]}" 2>&1 | tee "$log_file"

printf '\n--- Extracted performance and MTP diagnostics ---\n'
if ! grep -Ei 'prompt eval time|eval time|generation:|generated|tokens/s|tok/s|t/s|speculat|draft|accept' "$log_file"; then
  echo "No standard timing or speculative-decoding summary was found; inspect the transcript above."
fi

printf '\nConfigured context capacity was %s tokens. The prompt itself is short; this test measures full-KV-cache allocation plus generation throughput, not a 262K-token prefill.\n' "$CONTEXT_SIZE"
