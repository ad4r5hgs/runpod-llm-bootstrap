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

verify_gpu() {
  need_cmd nvidia-smi
  log "Checking NVIDIA GPU..."
  nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader
  local gpu_name cuda_driver
  gpu_name="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1)"
  cuda_driver="$(nvidia-smi | awk -F 'CUDA Version: ' '/CUDA Version:/ {print $2; exit}' | awk '{print $1}')"
  [[ "$gpu_name" == *"A40"* ]] || die "Expected an NVIDIA A40; detected: $gpu_name. Override this check only if you intentionally changed GPU."
  [[ "$cuda_driver" == "12.8" ]] || log "WARNING: nvidia-smi reports CUDA compatibility ${cuda_driver}; tested environment was 12.8."
}

install_hf_cli() {
  if command -v hf >/dev/null 2>&1; then
    log "Hugging Face CLI already installed: $(hf --help >/dev/null 2>&1 && hf --version 2>/dev/null || true)"
    return
  fi
  need_cmd python3
  log "Installing huggingface_hub CLI..."
  python3 -m pip install --disable-pip-version-check -q --no-input 'huggingface_hub[cli]'
  command -v hf >/dev/null 2>&1 || die "hf CLI installation failed."
}

resolve_llama_asset() {
  need_cmd curl
  need_cmd python3

  local release_json asset_url asset_name
  release_json="${INSTALL_DIR}/llama-release.json"
  curl -fsSL --retry 3 --retry-delay 2 \
    -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/${LLAMA_CPP_TAG}" \
    -o "$release_json"

  read -r asset_name asset_url < <(python3 - "$release_json" "$LLAMA_CPP_CUDA" <<'PY'
import json, re, sys
path, cuda = sys.argv[1:]
data = json.load(open(path, encoding='utf-8'))
assets = data.get('assets', [])
patterns = [
    rf'ubuntu-cuda-{re.escape(cuda)}.*x64.*\.zip$',
    rf'linux.*cuda[-_]{re.escape(cuda)}.*x64.*\.zip$',
]
for pat in patterns:
    rx = re.compile(pat, re.I)
    hits = [a for a in assets if rx.search(a.get('name',''))]
    if hits:
        a = hits[0]
        print(a['name'], a['browser_download_url'])
        raise SystemExit(0)
# Fallback: print useful candidates for diagnostics, then fail.
print("NO_MATCH", "", end="")
for a in assets:
    n = a.get('name','')
    if 'cuda' in n.lower() and n.lower().endswith('.zip'):
        print(n, a.get('browser_download_url',''))
raise SystemExit(2)
PY
  ) || {
    echo "Could not resolve a Linux CUDA ${LLAMA_CPP_CUDA} prebuilt asset for llama.cpp ${LLAMA_CPP_TAG}." >&2
    echo "Inspect ${release_json} or update the asset matching logic." >&2
    exit 1
  }

  [[ -n "$asset_url" ]] || die "Resolved asset URL is empty."
  LLAMA_ASSET_NAME="$asset_name"
  LLAMA_ASSET_URL="$asset_url"
  export LLAMA_ASSET_NAME LLAMA_ASSET_URL
  log "Resolved llama.cpp prebuilt asset: ${LLAMA_ASSET_NAME}"
}

install_llama_binary() {
  need_cmd curl
  need_cmd python3
  ensure_dir "$INSTALL_DIR"
  ensure_dir "$LLAMA_DIR"

  if [[ -x "${LLAMA_DIR}/llama-cli" && -x "${LLAMA_DIR}/llama-server" ]]; then
    log "llama.cpp prebuilt binaries already present."
    "${LLAMA_DIR}/llama-cli" --version || true
    return
  fi

  resolve_llama_asset
  local archive="${INSTALL_DIR}/${LLAMA_ASSET_NAME}"
  log "Downloading prebuilt llama.cpp binary..."
  curl -fL --retry 3 --retry-delay 2 --progress-bar "$LLAMA_ASSET_URL" -o "$archive"

  log "Extracting llama.cpp prebuilt package..."
  python3 - "$archive" "$LLAMA_DIR" <<'PY'
import sys, zipfile, os
archive, dest = sys.argv[1:]
os.makedirs(dest, exist_ok=True)
with zipfile.ZipFile(archive) as z:
    z.extractall(dest)
PY

  # Some release archives contain a top-level directory. Flatten it if needed.
  if [[ ! -x "${LLAMA_DIR}/llama-cli" ]]; then
    local cli_path
    cli_path="$(find "$LLAMA_DIR" -type f -name llama-cli -print -quit)"
    [[ -n "$cli_path" ]] || die "llama-cli not found after extracting $archive."
    local bindir
    bindir="$(dirname "$cli_path")"
    cp -a "$bindir"/* "$LLAMA_DIR"/
  fi

  [[ -x "${LLAMA_DIR}/llama-cli" ]] || die "llama-cli is missing after extraction."
  [[ -x "${LLAMA_DIR}/llama-server" ]] || die "llama-server is missing after extraction."
  chmod +x "${LLAMA_DIR}"/llama-* || true

  log "Installed prebuilt llama.cpp:"
  "${LLAMA_DIR}/llama-cli" --version || true
}

verify_llama_cuda() {
  log "Verifying CUDA backend and model tools..."
  local devices
  devices="$("${LLAMA_DIR}/llama-cli" --list-devices 2>&1)" || die "llama-cli could not enumerate devices."
  echo "$devices"
  echo "$devices" | grep -q 'CUDA0:' || die "Prebuilt llama.cpp does not expose a CUDA backend."
  echo "$devices" | grep -q 'NVIDIA A40' || die "llama.cpp does not see the NVIDIA A40."
}

download_model_file() {
  local file="$1" min_gb="$2"
  check_free_space_gb "$MODEL_DIR" "$min_gb"
  log "Downloading ${file}..."
  local extra_args=()
  [[ -n "${MODEL_REVISION:-}" ]] && extra_args+=(--revision "$MODEL_REVISION")
  [[ -n "${HF_TOKEN:-}" ]] && extra_args+=(--token "$HF_TOKEN")
  hf download "$MODEL_REPO" "$file" \
    --local-dir "$MODEL_DIR" \
    --max-workers "$HF_MAX_WORKERS" \
    "${extra_args[@]}"
  [[ -f "${MODEL_DIR}/${file}" ]] || die "Downloaded file missing: ${MODEL_DIR}/${file}"
}

write_manifest() {
  local manifest="${INSTALL_DIR}/manifest.env"
  cat > "$manifest" <<EOF_MANIFEST
LLAMA_CPP_TAG=${LLAMA_CPP_TAG}
LLAMA_CPP_EXPECTED_COMMIT=${LLAMA_CPP_EXPECTED_COMMIT}
LLAMA_CPP_CUDA=${LLAMA_CPP_CUDA}
MODEL_REPO=${MODEL_REPO}
MODEL_REVISION=${MODEL_REVISION}
MODEL_FILE=${MODEL_FILE}
MTP_FILE=${MTP_FILE}
SETUP_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF_MANIFEST
}

main() {
  [[ "$(id -u)" -eq 0 ]] || die "Run this setup as root (the default for the tested RunPod Pod)."
  need_cmd bash
  need_cmd curl
  need_cmd python3
  ensure_dir "$INSTALL_DIR"
  ensure_dir "$MODEL_DIR"

  verify_gpu
  check_free_space_gb "$MODEL_DIR" 38
  install_hf_cli
  install_llama_binary
  verify_llama_cuda

  if [[ ! -f "${MODEL_DIR}/${MODEL_FILE}" ]]; then
    download_model_file "$MODEL_FILE" 35
  else
    log "Main model already exists: ${MODEL_DIR}/${MODEL_FILE}"
  fi

  # After the main model is present, require at least 6 GiB before downloading MTP.
  if [[ ! -f "${MODEL_DIR}/${MTP_FILE}" ]]; then
    download_model_file "$MTP_FILE" 6
  else
    log "MTP model already exists: ${MODEL_DIR}/${MTP_FILE}"
  fi

  if [[ "${DOWNLOAD_VISION_PROJECTOR}" == "true" ]]; then
    log "Vision projector download requested. The exact filename must be set in config.env."
    download_model_file "$VISION_FILE" 2
  fi

  write_manifest

  log "Setup complete."
  echo "Main model: ${MODEL_DIR}/${MODEL_FILE}"
  echo "MTP model:  ${MODEL_DIR}/${MTP_FILE}"
  echo "llama.cpp:  ${LLAMA_DIR}"
  echo
  echo "Next: run ./run-cli.sh for an interactive text test, or ./run-server.sh for the local API/web UI."
}

main "$@"
