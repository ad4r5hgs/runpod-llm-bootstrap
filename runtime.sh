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
