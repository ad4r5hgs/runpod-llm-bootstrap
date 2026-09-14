#!/usr/bin/env bash

# Shared runtime helpers. Source this file after config.env has been loaded.

configure_llama_runtime() {
  [[ -n "${LLAMA_DIR:-}" ]] || {
    echo "ERROR: LLAMA_DIR is not configured." >&2
    return 1
  }
  [[ -d "$LLAMA_DIR" ]] || {
    echo "ERROR: llama.cpp directory does not exist: $LLAMA_DIR" >&2
    return 1
  }

  # ai-dock's b10182 package does not embed an RPATH for its sibling shared
  # libraries. Include the binary directory and every directory containing a
  # shared library so llama-cli and llama-server can start from any shell.
  local lib_dirs="$LLAMA_DIR"
  local dir
  while IFS= read -r dir; do
    [[ -n "$dir" ]] && lib_dirs="${lib_dirs}:${dir}"
  done < <(find "$LLAMA_DIR" -type f \( -name '*.so' -o -name '*.so.*' \) -exec dirname {} \; 2>/dev/null | sort -u)

  if [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
    export LD_LIBRARY_PATH="${lib_dirs}:${LD_LIBRARY_PATH}"
  else
    export LD_LIBRARY_PATH="$lib_dirs"
  fi
}

build_reasoning_args() {
  local mode="${REASONING_MODE:-auto}"
  local budget="${REASONING_BUDGET:-}"

  case "$mode" in
    on|off|auto) ;;
    *)
      echo "ERROR: REASONING_MODE must be one of: on, off, auto; got: $mode" >&2
      return 1
      ;;
  esac

  if [[ -n "$budget" ]]; then
    [[ "$budget" =~ ^-?[0-9]+$ ]] || {
      echo "ERROR: REASONING_BUDGET must be an integer; got: $budget" >&2
      return 1
    }
    (( budget >= -1 )) || {
      echo "ERROR: REASONING_BUDGET must be -1 or greater; got: $budget" >&2
      return 1
    }
  fi

  REASONING_ARGS=(--reasoning "$mode")
  [[ -n "$budget" ]] && REASONING_ARGS+=(--reasoning-budget "$budget")
  export REASONING_MODE REASONING_BUDGET
}

build_performance_args() {
  local flash_attn="${FLASH_ATTN:-auto}"
  local cache_type_k="${CACHE_TYPE_K:-f16}"
  local cache_type_v="${CACHE_TYPE_V:-f16}"
  local batch_size="${BATCH_SIZE:-2048}"
  local ubatch_size="${UBATCH_SIZE:-512}"

  case "$flash_attn" in
    on|off|auto) ;;
    *)
      echo "ERROR: FLASH_ATTN must be one of: on, off, auto; got: $flash_attn" >&2
      return 1
      ;;
  esac

  for value_name in CONTEXT_SIZE BATCH_SIZE UBATCH_SIZE; do
    local value="${!value_name:-}"
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
      echo "ERROR: ${value_name} must be a positive integer; got: ${value:-empty}" >&2
      return 1
    }
  done

  (( ubatch_size <= batch_size )) || {
    echo "ERROR: UBATCH_SIZE must not exceed BATCH_SIZE." >&2
    return 1
  }

  [[ "$cache_type_v" == "f16" || "$cache_type_v" == "f32" || "$flash_attn" != "off" ]] || {
    echo "ERROR: Quantized CACHE_TYPE_V requires FLASH_ATTN=on or auto." >&2
    return 1
  }

  PERFORMANCE_ARGS=(
    --flash-attn "$flash_attn"
    --cache-type-k "$cache_type_k"
    --cache-type-v "$cache_type_v"
    --batch-size "$batch_size"
    --ubatch-size "$ubatch_size"
  )
  export FLASH_ATTN CACHE_TYPE_K CACHE_TYPE_V BATCH_SIZE UBATCH_SIZE
}

build_server_args() {
  local parallel="${SERVER_PARALLEL:-1}"
  [[ "$parallel" =~ ^[1-9][0-9]*$ ]] || {
    echo "ERROR: SERVER_PARALLEL must be a positive integer; got: ${parallel:-empty}" >&2
    return 1
  }

  SERVER_RUNTIME_ARGS=(--parallel "$parallel")
  export SERVER_PARALLEL
}

# Step 1 helper tuning: builds the native MTP (draft-mtp) flag set.
# MTP_DRAFT_N_MAX is required. MTP_DRAFT_P_MIN is optional; when empty the
# flag is omitted so older builds such as b10182 keep working. When set, the
# caller must have a binary whose --help lists --spec-draft-p-min.
build_mtp_args() {
  local n_max="${MTP_DRAFT_N_MAX:-3}"
  local p_min="${MTP_DRAFT_P_MIN:-}"
  local draft_ngl="${MTP_GPU_LAYERS:-999}"

  [[ "$n_max" =~ ^[1-9][0-9]*$ ]] || {
    echo "ERROR: MTP_DRAFT_N_MAX must be a positive integer; got: ${n_max:-empty}" >&2
    return 1
  }
  [[ "$draft_ngl" =~ ^[0-9]+$ ]] || {
    echo "ERROR: MTP_GPU_LAYERS must be a non-negative integer; got: ${draft_ngl:-empty}" >&2
    return 1
  }

  if [[ -n "$p_min" ]]; then
    [[ "$p_min" =~ ^(0(\.[0-9]+)?|1(\.0*)?)$ ]] || {
      echo "ERROR: MTP_DRAFT_P_MIN must be a number between 0 and 1; got: $p_min" >&2
      return 1
    }
  fi

  [[ -n "${MODEL_DIR:-}" && -n "${MTP_FILE:-}" ]] || {
    echo "ERROR: MODEL_DIR/MTP_FILE must be configured before building MTP args." >&2
    return 1
  }

  MTP_ARGS=(
    --spec-type draft-mtp
    --spec-draft-model "${MODEL_DIR}/${MTP_FILE}"
    --spec-draft-ngl "$draft_ngl"
    --spec-draft-n-max "$n_max"
  )
  [[ -n "$p_min" ]] && MTP_ARGS+=(--spec-draft-p-min "$p_min")
  MTP_DRAFT_N_MAX="$n_max"
  MTP_DRAFT_P_MIN="$p_min"
  MTP_GPU_LAYERS="$draft_ngl"
  export MTP_DRAFT_N_MAX MTP_DRAFT_P_MIN MTP_GPU_LAYERS
}
