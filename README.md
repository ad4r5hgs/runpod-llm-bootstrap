# Qwen3.8-27B Uncensored — RunPod A40 bootstrap

This repository bootstraps a reproducible RunPod environment for the validated text-inference configuration:

- GPU: NVIDIA A40 48 GiB-class card (~46,068 MiB reported by RunPod)
- Host: Linux x86_64
- Validated CUDA toolkit: 12.8
- Validated prebuilt llama.cpp package: b10182 / commit prefix `afeebe1`
- Package source: prebuilt CUDA 12.8 archive from `ai-dock/llama.cpp-cuda`
- Main model: `philbert440/Qwen3.8-27B-Uncensored-Aggressive-GGUF`
- Main quant: Q8_0
- MTP head: Q8_0
- Default runtime context: 262,144 tokens (experimental full-context allocation)
- Default MTP draft length: 3
- Default reasoning mode: `off` for the throughput experiment (`b10182` does not support the newer `--reasoning-effort` preset)

The selected Philbert GGUF repository is the α=1.15 Aggressive recipe. The repository contains the main Q8_0 weights (~28.6 GB), an MTP Q8_0 head (~3.16 GB), and optional vision projector files. The file names use `Balanced` even though the repository itself is named `Aggressive`; do not rename them.

## Terminology

- **Prebuilt binary/package**: a compiled llama.cpp executable archive. This is what this bootstrap prefers instead of compiling llama.cpp from source on every fresh Pod.
- **Container image**: the Docker/OCI environment used to start the Pod. This repository does not build a custom image.
- **Inference engine/runtime**: llama.cpp. It loads the GGUF model and executes inference on the NVIDIA GPU.

## Quick start

```bash
cp config.env.example config.env
./setup.sh
./doctor.sh
./run-cli.sh
```

`setup.sh` is intentionally fail-fast. It validates the host, downloads the validated prebuilt CUDA llama.cpp package, configures its shared-library path, downloads the Q8 and MTP model files, verifies CUDA visibility, then runs a short real inference smoke test with and without MTP. The default smoke test allocates the full 262K KV cache, so it is an intentional fit test on a paid GPU. It does not clone or compile llama.cpp.

## Environment detection

The bootstrap does **not** require `nvidia-smi` to report CUDA 12.8 exactly. `nvidia-smi` reports the driver's supported CUDA level, while `nvcc` (when present) reports the installed toolkit. On the second test Pod, for example, the driver reported CUDA 13.0 while the installed toolkit and PyTorch were CUDA 12.8; this is a valid configuration.

The bootstrap therefore validates:

1. Linux + x86_64.
2. NVIDIA GPU and VRAM.
3. Driver availability.
4. Optional CUDA toolkit presence (informational only for the prebuilt path).
5. Actual llama.cpp CUDA backend visibility with `llama-cli --list-devices`.
6. Actual Q8 inference.
7. Actual Q8 + native MTP inference.

A40 is the validated target. Other NVIDIA GPUs can be permitted by setting `REQUIRE_A40=false`, provided they meet the configured VRAM requirement and pass the CUDA smoke test.

## Prebuilt llama.cpp note

The upstream llama.cpp project publishes prebuilt binaries, but Linux CUDA builds are supplied by external build/distribution projects rather than the normal upstream Linux release set. This repository uses `ai-dock/llama.cpp-cuda` for the CUDA 12.8 Linux x86_64 package path.

The bootstrap pins the provider's `b10182` release and expects the exact
`llama.cpp-b10182-cuda-12.8-amd64.tar.gz` asset. This package was validated on
an A40 for startup, CUDA device detection, native MTP flag availability, and
Q8 inference without MTP. The package requires `LD_LIBRARY_PATH` to include
its shared-library directory; the scripts configure this automatically.

The script intentionally fails rather than silently compiling llama.cpp if the
prebuilt asset is unavailable. The previously tested source build `b10603` /
`c060ca974` remains a manual fallback, but source compilation is not performed
by this bootstrap.

## Storage model

The intended RunPod setup is ephemeral container storage. The model files are redownloaded on a fresh Pod. The Q8 main model and MTP head together consume about 32 GB, so the example configuration expects at least 40 GiB free before downloading them.

## Smoke tests

`setup.sh` performs two short runtime tests:

1. Q8 main model on CUDA with MTP disabled.
2. Q8 main model + native MTP (`draft-mtp`) using the Q8 MTP head.

The smoke tests use only a few predicted tokens, but the configured 262K context
still allocates the full KV cache. They are intended to prove that the exact
full-context configuration fits and executes, not to benchmark performance.

## Runtime

`run-cli.sh` starts the configured full-context throughput experiment:

- Q8_0
- all model layers on GPU
- 262K context, one active sequence
- native MTP
- MTP `n-max=3`
- Flash Attention with Q4_0 K/V cache
- reasoning disabled by default; optionally re-enable it or add a numeric `REASONING_BUDGET`
  in `config.env`

Q4_0 KV cache is a memory/performance trade-off and may affect long-context
quality. If the full-context allocation fails on the A40, do not partially
offload weights to CPU: lower `CONTEXT_SIZE` or use a larger GPU instead.

## Remote endpoint (secondary phase)

`llama-server` provides an HTTP server, web UI, and OpenAI-compatible API routes. The later remote phase should use:

- `--host 0.0.0.0`
- `--port 8080`
- an API key
- RunPod's HTTP proxy or another authenticated HTTPS front end

Do not expose an unauthenticated llama-server directly to the public internet.
