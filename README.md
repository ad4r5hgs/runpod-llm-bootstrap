# Qwen3.8-27B Uncensored — RunPod A40 bootstrap

This repository bootstraps a reproducible RunPod environment for the tested configuration:

- GPU: NVIDIA A40 48 GiB
- CUDA compatibility reported by `nvidia-smi`: 12.8
- llama.cpp: b10603 / commit `c060ca974`
- Main model: `philbert440/Qwen3.8-27B-Uncensored-Aggressive-GGUF`
- Main quant: Q8_0
- MTP head: Q8_0
- Default runtime context: 65,536 tokens
- Default MTP draft length: 4
- Default Qwen reasoning effort: `medium`

The selected Philbert GGUF repository is the α=1.15 Aggressive recipe. The repository contains the main Q8_0 weights (~28.6 GB), an MTP Q8_0 head (~3.16 GB), and optional vision projector files. The file names use `Balanced` even though the repository itself is named `Aggressive`; do not rename them.

## Terminology

- **Prebuilt binary/package**: a compiled llama.cpp executable archive. This is what we use here instead of compiling llama.cpp from source on every fresh Pod.
- **Container image**: the Docker/OCI environment used to start the Pod. This repository does not build a custom image.
- **Inference engine/runtime**: llama.cpp. It loads the GGUF model and executes inference on the NVIDIA GPU.

## Quick start

```bash
cp config.env.example config.env
./setup.sh
./doctor.sh
./run-cli.sh
```

For the tested remote-ready server path, see `run-server.sh`; keep `SERVER_HOST=127.0.0.1` until remote access and authentication are deliberately configured.

## Why the script is defensive

The script:

1. Pins the llama.cpp release used during the successful experiment instead of tracking `latest`.
2. Queries the GitHub release API and selects the Linux x64 CUDA 12.8 prebuilt asset; it does not assume a brittle hard-coded asset filename.
3. Refuses to proceed if the A40 is not visible.
4. Checks disk headroom before each large model download.
5. Installs the Hugging Face CLI only if it is missing.
6. Downloads only the main Q8_0 and MTP Q8_0 files by default, avoiding the optional vision projector.
7. Avoids compiling llama.cpp on the paid GPU.
8. Verifies that the resulting llama.cpp binary exposes CUDA and sees the A40.
9. Uses the exact runtime parameters that were experimentally successful: Q8_0, all GPU layers, MTP, MTP n-max=4, medium reasoning.
10. Keeps the context size configurable. The default is 64K because that is explicitly established in the experiment. Set `CONTEXT_SIZE=131072` only after confirming 128K works reliably in the current environment.
11. Refuses to expose the API server on a non-loopback address without an API key.
12. Keeps credentials outside Git via `config.env` and `.gitignore`.
13. Writes a small manifest containing the versions/revisions used for the deployment.

## Storage model

The intended RunPod setup is ephemeral container storage. The model files are redownloaded on a fresh Pod. The script expects enough local disk for approximately 32 GB of model files plus runtime artifacts.

## Remote endpoint (secondary phase)

`llama-server` provides an HTTP server, an easy web UI, and OpenAI-compatible API routes. The later remote phase should use:

- `--host 0.0.0.0`
- `--port 8080`
- an API key
- RunPod's HTTP proxy or another authenticated HTTPS front end

Do not expose an unauthenticated llama-server directly to the public internet.
