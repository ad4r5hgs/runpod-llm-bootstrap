#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/config.env}"

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
else
  echo "ERROR: $CONFIG_FILE not found. Copy config.env.example to config.env first." >&2
  exit 1
fi

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/runtime.sh"

REASONING_MODE="${REASONING_MODE:-auto}"
REASONING_BUDGET="${REASONING_BUDGET:-}"

log() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

ensure_dir() { mkdir -p "$1"; }

check_free_space_gb() {
  local path="$1" min_gb="$2" avail_kb avail_gb
  avail_kb="$(df -Pk "$path" | awk 'NR==2 {print $4}')"
  avail_gb=$((avail_kb / 1024 / 1024))
  (( avail_gb >= min_gb )) || die "Only ${avail_gb} GiB free on $(df -P "$path" | awk 'NR==2 {print $6}'); need at least ${min_gb} GiB."
  log "Disk preflight: ${avail_gb} GiB free."
}

verify_platform() {
  local arch os
  arch="$(uname -m)"
  [[ "$arch" == "x86_64" ]] || die "Unsupported host architecture: ${arch}. This bootstrap currently targets Linux x86_64."
  os="$(uname -s)"
  [[ "$os" == "Linux" ]] || die "Unsupported operating system: ${os}."
  log "Platform: ${os} ${arch}"
}

verify_gpu() {
  need_cmd nvidia-smi
  log "Checking NVIDIA GPU and driver..."
  nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader

  local gpu_name gpu_mem_mib driver_version
  gpu_name="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1)"
  gpu_mem_mib="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -n1 | awk '{print int($1)}')"
  driver_version="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1)"

  [[ -n "$gpu_name" ]] || die "NVIDIA GPU not detected."
  [[ -n "$gpu_mem_mib" ]] || die "Could not determine GPU memory."
  [[ "$gpu_name" == *"A40"* ]] || {
    if [[ "${REQUIRE_A40:-true}" == "true" ]]; then
      die "Expected an NVIDIA A40; detected: ${gpu_name}. Set REQUIRE_A40=false only if you intentionally want to run on another supported NVIDIA GPU."
    fi
    log "WARNING: detected ${gpu_name}; A40 is the validated target."
  }

  local min_vram_mib=$((MIN_VRAM_GIB * 1024))
  (( gpu_mem_mib >= min_vram_mib )) || die "GPU has ${gpu_mem_mib} MiB VRAM; need at least ${MIN_VRAM_GIB} GiB for the configured Q8+MTP deployment."

  log "GPU: ${gpu_name}; VRAM: ${gpu_mem_mib} MiB; driver: ${driver_version}"

  if command -v nvcc >/dev/null 2>&1; then
    log "CUDA toolkit detected: $(nvcc --version | awk -F'release ' '/release / {print $2}' | awk -F, 'NR==1{print $1}')"
  else
    log "CUDA toolkit (nvcc) not installed; continuing because the prebuilt llama.cpp binary supplies the CUDA runtime."
  fi
}

install_hf_cli() {
  need_cmd python3
  log "Installing huggingface_hub CLI in a dedicated virtual environment..."
  local hf_venv="${INSTALL_DIR}/hf-venv"
  if [[ ! -x "${hf_venv}/bin/hf" ]]; then
    python3 -m venv "$hf_venv" || die "Could not create a Python virtual environment."
    "${hf_venv}/bin/python" -m pip install --disable-pip-version-check -q --no-input -U pip huggingface_hub || die "Failed to install huggingface_hub."
  fi
  HF_BIN="${hf_venv}/bin/hf"
  export HF_BIN
  "${HF_BIN}" --help >/dev/null 2>&1 || die "Hugging Face CLI installation failed."
}

resolve_llama_asset() {
  need_cmd curl
  need_cmd python3

  local release_json asset_url asset_name
  release_json="${INSTALL_DIR}/llama-provider-release.json"

  log "Resolving prebuilt llama.cpp CUDA ${LLAMA_CPP_CUDA} for ${LLAMA_CPP_TAG}..."
  curl -fsSL --retry 3 --retry-delay 2 \
    -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/${LLAMA_CPP_PROVIDER}/releases/tags/${LLAMA_CPP_TAG}" \
    -o "$release_json" || die "Could not query ${LLAMA_CPP_PROVIDER} for release ${LLAMA_CPP_TAG}."

  # The script-wide IFS intentionally excludes spaces. Override it here so
  # Python's space-separated asset name and URL are read into two variables.
  IFS=$' \t' read -r asset_name asset_url < <(python3 - "$release_json" "$LLAMA_CPP_CUDA" "${LLAMA_CPP_ASSET_NAME:-}" <<'PY'
import json, re, sys
path, cuda, expected_name = sys.argv[1:]
data = json.load(open(path, encoding='utf-8'))
assets = data.get('assets', [])
if expected_name:
    hits = [a for a in assets if a.get('name', '') == expected_name]
    if hits:
        a = hits[0]
        print(a['name'], a['browser_download_url'])
        raise SystemExit(0)
else:
    patterns = [
        rf'^llama\.cpp-b\d+-cuda-{re.escape(cuda)}-amd64\.tar\.gz$',
        rf'^llama-b\d+-bin-ubuntu-cuda-{re.escape(cuda)}-x64\.tar\.gz$',
    ]
    for pat in patterns:
        rx = re.compile(pat, re.I)
        hits = [a for a in assets if rx.fullmatch(a.get('name',''))]
        if hits:
            a = hits[0]
            print(a['name'], a['browser_download_url'])
            raise SystemExit(0)
print("NO_MATCH", "", end="")
raise SystemExit(2)
PY
  ) || {
    echo "No prebuilt Linux x86_64 CUDA ${LLAMA_CPP_CUDA} asset was found for ${LLAMA_CPP_PROVIDER} release ${LLAMA_CPP_TAG}." >&2
    echo "This bootstrap intentionally refuses to compile llama.cpp automatically on a paid GPU." >&2
    echo "Use a known compatible prebuilt release or explicitly add a source-build fallback later." >&2
    exit 1
  }

  [[ -n "$asset_url" ]] || die "Resolved llama.cpp asset URL is empty."
  LLAMA_ASSET_NAME="$asset_name"
  LLAMA_ASSET_URL="$asset_url"
  export LLAMA_ASSET_NAME LLAMA_ASSET_URL
  log "Resolved llama.cpp prebuilt asset: ${LLAMA_ASSET_NAME}"
}

verify_llama_version() {
  local version_output
  version_output="$("${LLAMA_DIR}/llama-cli" --version 2>&1)" || die "llama-cli --version failed."
  echo "$version_output"

  if [[ -n "${LLAMA_CPP_EXPECTED_COMMIT:-}" ]]; then
    echo "$version_output" | grep -Fq "$LLAMA_CPP_EXPECTED_COMMIT" || die "llama.cpp binary does not report expected commit ${LLAMA_CPP_EXPECTED_COMMIT}."
  fi
}

install_llama_binary() {
  need_cmd curl
  need_cmd python3
  ensure_dir "$INSTALL_DIR"
  ensure_dir "$LLAMA_DIR"

  if [[ -x "${LLAMA_DIR}/llama-cli" && -x "${LLAMA_DIR}/llama-server" ]]; then
    log "llama.cpp prebuilt binaries already present."
    configure_llama_runtime || die "Could not configure llama.cpp shared-library paths."
    verify_runtime_dependencies
    verify_llama_version
    return
  fi

  resolve_llama_asset
  local archive="${INSTALL_DIR}/${LLAMA_ASSET_NAME}"
  log "Downloading prebuilt llama.cpp binary..."
  curl -fL --retry 3 --retry-delay 2 --progress-bar "$LLAMA_ASSET_URL" -o "$archive"

  log "Extracting llama.cpp prebuilt package..."
  tar -xzf "$archive" -C "$LLAMA_DIR" || die "Failed to extract ${archive}."

  if [[ ! -x "${LLAMA_DIR}/llama-cli" || ! -x "${LLAMA_DIR}/llama-server" ]]; then
    local cli_path server_path cli_dir server_dir
    cli_path="$(find "$LLAMA_DIR" -type f -name llama-cli -print -quit)"
    server_path="$(find "$LLAMA_DIR" -type f -name llama-server -print -quit)"
    [[ -n "$cli_path" ]] || die "llama-cli not found after extracting $archive."
    [[ -n "$server_path" ]] || die "llama-server not found after extracting $archive."
    cli_dir="$(dirname "$cli_path")"
    server_dir="$(dirname "$server_path")"
    [[ "$cli_dir" == "$LLAMA_DIR" ]] || cp -a "$cli_dir"/. "$LLAMA_DIR"/
    if [[ "$server_dir" != "$cli_dir" && "$server_dir" != "$LLAMA_DIR" ]]; then
      cp -a "$server_dir"/. "$LLAMA_DIR"/
    fi
  fi

  [[ -x "${LLAMA_DIR}/llama-cli" ]] || die "llama-cli is missing after extraction."
  [[ -x "${LLAMA_DIR}/llama-server" ]] || die "llama-server is missing after extraction."
  chmod +x "${LLAMA_DIR}"/llama-* || true

  configure_llama_runtime || die "Could not configure llama.cpp shared-library paths."
  verify_runtime_dependencies
  verify_llama_version
}

verify_runtime_dependencies() {
  local binary missing
  for binary in "${LLAMA_DIR}/llama-cli" "${LLAMA_DIR}/llama-server"; do
    missing="$(ldd "$binary" 2>&1 | grep 'not found' || true)"
    if [[ -n "$missing" ]]; then
      echo "$missing" >&2
      die "$(basename "$binary") has missing shared-library dependencies."
    fi
  done
}

verify_llama_cuda() {
  log "Verifying CUDA backend and A40 visibility..."
  local devices
  devices="$(${LLAMA_DIR}/llama-cli --list-devices 2>&1)" || die "llama-cli could not enumerate devices."
  echo "$devices"
  echo "$devices" | grep -q 'CUDA0:' || die "Prebuilt llama.cpp does not expose a CUDA backend."
  if [[ "${REQUIRE_A40:-true}" == "true" ]]; then
    echo "$devices" | grep -q 'NVIDIA A40' || die "llama.cpp does not see the NVIDIA A40."
  fi
}

verify_runtime_config() {
  build_reasoning_args || die "Invalid reasoning configuration."
  build_performance_args || die "Invalid performance configuration."
  build_server_args || die "Invalid server configuration."
}

verify_performance_flags() {
  local help_output
  help_output="$("${LLAMA_DIR}/llama-cli" --help 2>&1)" || die "llama-cli --help failed."

  for flag in --flash-attn --cache-type-k --cache-type-v --batch-size --ubatch-size; do
    grep -Fq -- "$flag" <<< "$help_output" || die "Pinned llama.cpp build does not support ${flag}; select a compatible build before running the full-context experiment."
  done

  help_output="$("${LLAMA_DIR}/llama-server" --help 2>&1)" || die "llama-server --help failed."
  grep -Fq -- '--parallel' <<< "$help_output" || die "Pinned llama.cpp build does not support --parallel."
}

model_size_bytes() {
  local file="$1"
  "${HF_BIN}" download "$MODEL_REPO" "$file" --repo-type model --revision "$MODEL_REVISION" --dry-run 2>/dev/null \
    | python3 -c 'import re,sys; s=sys.stdin.read(); m=re.search(r"(?i)(\d+(?:\.\d+)?)(?:\s*)([KMG]B|B)", s); print("0") if not m else print(int(float(m.group(1)) * {"B":1,"KB":1024,"MB":1024**2,"GB":1024**3}[m.group(2).upper()]))' \
    | head -n1
}

download_model_file() {
  local file="$1"
  log "Downloading ${file}..."
  local extra_args=()
  [[ -n "${MODEL_REVISION:-}" ]] && extra_args+=(--revision "$MODEL_REVISION")
  [[ -n "${HF_TOKEN:-}" ]] && extra_args+=(--token "$HF_TOKEN")
  "${HF_BIN}" download "$MODEL_REPO" "$file" \
    --local-dir "$MODEL_DIR" \
    --max-workers "$HF_MAX_WORKERS" \
    "${extra_args[@]}" || die "Failed to download ${file}."
  [[ -f "${MODEL_DIR}/${file}" ]] || die "Downloaded file missing: ${MODEL_DIR}/${file}"
}

verify_model_files() {
  [[ -s "${MODEL_DIR}/${MODEL_FILE}" ]] || die "Main model is missing or empty."
  [[ -s "${MODEL_DIR}/${MTP_FILE}" ]] || die "MTP model is missing or empty."
  log "Main model: $(du -h "${MODEL_DIR}/${MODEL_FILE}" | awk '{print $1}')"
  log "MTP model:  $(du -h "${MODEL_DIR}/${MTP_FILE}" | awk '{print $1}')"
}

smoke_test_q8() {
  log "Running Q8 CUDA inference smoke test (MTP disabled)..."
  local output
  output="$(${LLAMA_DIR}/llama-cli \
    --model "${MODEL_DIR}/${MODEL_FILE}" \
    --gpu-layers "${GPU_LAYERS}" \
    --ctx-size "${SMOKE_CTX_SIZE}" \
    "${PERFORMANCE_ARGS[@]}" \
    --n-predict "${SMOKE_N_PREDICT}" \
    "${REASONING_ARGS[@]}" \
    --prompt "${SMOKE_PROMPT}" 2>&1)" || {
      printf '%s\n' "$output"
      die "Q8 CUDA inference smoke test failed."
    }
  printf '%s\n' "$output"
  echo "$output" | grep -Eq 'Generation:|generated|tokens' || die "Q8 smoke test completed without recognizable generation statistics."
}

smoke_test_mtp() {
  log "Running Q8 + native MTP inference smoke test..."
  local output
  output="$(${LLAMA_DIR}/llama-cli \
    --model "${MODEL_DIR}/${MODEL_FILE}" \
    --gpu-layers "${GPU_LAYERS}" \
    --ctx-size "${SMOKE_CTX_SIZE}" \
    --spec-type draft-mtp \
    --spec-draft-model "${MODEL_DIR}/${MTP_FILE}" \
    --spec-draft-ngl "${MTP_GPU_LAYERS}" \
    --spec-draft-n-max "${MTP_DRAFT_N_MAX}" \
    "${PERFORMANCE_ARGS[@]}" \
    "${REASONING_ARGS[@]}" \
    --n-predict "${SMOKE_N_PREDICT}" \
    --prompt "${SMOKE_PROMPT}" 2>&1)" || {
      printf '%s\n' "$output"
      die "Q8 + MTP inference smoke test failed."
    }
  printf '%s\n' "$output"
  echo "$output" | grep -Eq 'Generation:|generated|tokens' || die "MTP smoke test completed without recognizable generation statistics."
}

write_manifest() {
  local manifest="${INSTALL_DIR}/manifest.env"
  cat > "$manifest" <<EOF_MANIFEST
LLAMA_CPP_PROVIDER=${LLAMA_CPP_PROVIDER}
LLAMA_CPP_TAG=${LLAMA_CPP_TAG}
LLAMA_CPP_EXPECTED_COMMIT=${LLAMA_CPP_EXPECTED_COMMIT}
LLAMA_CPP_CUDA=${LLAMA_CPP_CUDA}
LLAMA_ASSET_NAME=${LLAMA_ASSET_NAME:-}
MODEL_REPO=${MODEL_REPO}
MODEL_REVISION=${MODEL_REVISION}
MODEL_FILE=${MODEL_FILE}
MTP_FILE=${MTP_FILE}
GPU_LAYERS=${GPU_LAYERS}
MTP_GPU_LAYERS=${MTP_GPU_LAYERS}
MTP_DRAFT_N_MAX=${MTP_DRAFT_N_MAX}
CONTEXT_SIZE=${CONTEXT_SIZE}
FLASH_ATTN=${FLASH_ATTN}
CACHE_TYPE_K=${CACHE_TYPE_K}
CACHE_TYPE_V=${CACHE_TYPE_V}
BATCH_SIZE=${BATCH_SIZE}
UBATCH_SIZE=${UBATCH_SIZE}
SERVER_PARALLEL=${SERVER_PARALLEL}
REASONING_MODE=${REASONING_MODE}
REASONING_BUDGET=${REASONING_BUDGET}
SETUP_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF_MANIFEST
}

main() {
  [[ "$(id -u)" -eq 0 ]] || die "Run this setup as root (the default for the tested RunPod Pod)."
  need_cmd bash
  need_cmd curl
  need_cmd ldd
  need_cmd python3
  ensure_dir "$INSTALL_DIR"
  ensure_dir "$MODEL_DIR"

  verify_platform
  verify_gpu
  verify_runtime_config
  check_free_space_gb "$MODEL_DIR" "$MIN_FREE_DISK_GIB"
  install_hf_cli
  install_llama_binary
  verify_llama_cuda
  verify_performance_flags

  if [[ ! -f "${MODEL_DIR}/${MODEL_FILE}" ]]; then
    download_model_file "$MODEL_FILE"
  else
    log "Main model already exists: ${MODEL_DIR}/${MODEL_FILE}"
  fi

  if [[ ! -f "${MODEL_DIR}/${MTP_FILE}" ]]; then
    download_model_file "$MTP_FILE"
  else
    log "MTP model already exists: ${MODEL_DIR}/${MTP_FILE}"
  fi

  verify_model_files

  if [[ "${DOWNLOAD_VISION_PROJECTOR}" == "true" ]]; then
    log "Vision projector download requested. The exact filename must be set in config.env."
    download_model_file "$VISION_FILE"
  fi

  write_manifest
  smoke_test_q8
  smoke_test_mtp

  log "Setup complete: CUDA + Q8 model + MTP have all passed smoke tests."
  echo "Main model: ${MODEL_DIR}/${MODEL_FILE}"
  echo "MTP model:  ${MODEL_DIR}/${MTP_FILE}"
  echo "llama.cpp:  ${LLAMA_DIR}"
  echo "Context default: ${CONTEXT_SIZE}"
  echo "MTP n-max: ${MTP_DRAFT_N_MAX}"
  echo "Reasoning: ${REASONING_MODE}${REASONING_BUDGET:+ (budget ${REASONING_BUDGET})}"
}

main "$@"
