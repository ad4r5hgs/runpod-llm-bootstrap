# Qwen3.8-27B hosting: short evidence report

**Research date:** 8 September 2026.  **Scope:** Qwen/Qwen3.8-27B (27B dense, hybrid Gated DeltaNet/attention, native 262K context) and its community *abliterated/uncensored* derivatives. “Tokens/s” below is generated/decode output unless explicitly labelled aggregate or prefill. It is not valid to compare aggregate throughput at concurrency 8 to a single-user rate.

## Bottom line

For this repository’s **single A40 48 GB RunPod** target, use the existing **CUDA `llama.cpp` + GGUF** path, fully GPU-offloaded, with native MTP and a 65K context to start. It is the robust, low-ops way to serve an uncensored GGUF and still has ample VRAM for a Q8 target plus MTP head. There is no like-for-like public A40 benchmark I found, so do not promise a specific TPS before measuring it on the Pod.

If the sole objective is **maximum tokens/s**, rent a **single H200, RTX 5090, or RTX PRO 6000 Blackwell** and use **SGLang + NVFP4 + DFlash2**. On one H200, the DFlash2 authors report 184–236 tok/s at concurrency 1 and 1,090–1,368 aggregate tok/s at concurrency 8, versus 69 and 467–480 tok/s respectively without speculation. These are benchmark-task results, not a general SLA. [Method and results](https://huggingface.co/z-lab/Qwen3.8-27B-DFlash2?library=transformers)

Choose the **official Qwen/Qwen3.8-27B or -FP8** checkpoint for predictable quality, official compatibility, vision, tools, and support. Choose an **uncensored/abliterated GGUF** only when that behavioural change is intentional: it does not intrinsically make the model faster. Its performance is determined by quantization, serving engine, GPU offload, context/KV format, and speculative decoding; community derivatives need their own quality and security evaluation.

## Best configurations reported online

| Goal / hardware | Model and serving configuration | Measured result | Takeaway |
|---|---|---:|---|
| **Highest single-node server throughput** — 1× H200 | Official BF16 Qwen3.8-27B; **SGLang**, FlashAttention 3; DFlash2 draft `incoai/Qwen3.8-27B-DFlash2`; 7 drafted tokens/verification; xhigh reasoning in test | **184–236 tok/s** C1; **1,090–1,368 aggregate tok/s** C8, depending on task | Best credible, fully described performance dataset found. DFlash2 is 2.27–3.43× autoregressive. [Evidence](https://huggingface.co/z-lab/Qwen3.8-27B-DFlash2?library=transformers) |
| Maximum RTX 5090 experiment — 32 GB | Qwen3.8-27B **NVFP4**, NVFP4 KV, DFlash2 K=7, **vLLM 0.27.1 + unpublished overlay**, FlashInfer backport, thinking off, 262K | **616 aggregate tok/s** at C4, 1,536-token code outputs | Impressive but not a stable, stock-vLLM recipe; treat as an experimental ceiling. [Configuration](https://www.reddit.com/r/Vllm/comments/1vy9cqt/ran_qwen3827b_on_a_single_5090_with_nvfp4_weights/) |
| Fast supported Blackwell single-GPU | Qwen3.8 NVFP4 + DSpark, **SGLang** on RTX 5090 / RTX PRO 6000 | **200+ tok/s** decode claimed | Use SGLang’s model-specific cookbook/image; it specifies FlashInfer on SM120/121 and automatically uses the checkpoint’s FP8 KV calibration. [Cookbook](https://docs.sglang.io/cookbook/autoregressive/Qwen/Qwen3.8-27B) |
| Reproducible high-quality local — 1× RTX 5090 | Q4_K_M GGUF; **llama.cpp b10448 CUDA**; 32K context; native MTP | 73.6 tok/s MTP off; **133.6 tok/s at MTP n=3** (1.81×) | The clearest controlled local sweep. MTP n=3 beat n=1/2/4/5 on this hardware; it consumed roughly 980 MB extra versus no MTP. [45-setting sweep](https://huggingface.co/Qwen/Qwen3.8-27B/discussions/112) |
| Plain, independently recorded local baseline — 1× RTX 5090 | Q4_K_M GGUF; **llama.cpp** commit `9725a31`; all 65 layers GPU; thinking off | **65.1–65.7 tok/s** decode; 865–3,506 prefill tok/s; 117–132 ms short TTFT | Useful conservative baseline, but it does not state MTP use and therefore should not be compared to speculative figures. [Run details](https://llm-speed.com/m/qwen3-8-27b) |
| 24-GB card / long context | Q4_K_M GGUF, **LM Studio / llama.cpp**; RTX 4090; all layers GPU; K/V Q4_0; Flash Attention; MTP 2; 160,927 context | **47–57 tok/s** daily decode | Shows why hybrid attention makes long context practical. It is a user report, not a controlled benchmark. [Exact settings](https://www.reddit.com/r/Qwen_AI/comments/1vqzl5l/qwen3827b_at_160k_context_on_a_single_rtx_4090/) |
| 24-GB Ampere / vision | Q4_K_M, **llama.cpp b10217 CUDA**, RTX 3090; vision on, 131K context; MTP 2 | 65.3 base / **75.1 tok/s MTP**; 705 prefill tok/s at 128K | For an Ampere vision error, `GGML_CUDA_CUBLAS_COMPUTE_TYPE=fp32` reportedly fixed it with no measured decode cost. [Benchmark](https://www.reddit.com/r/LocalLLM/comments/1vr7ryo/qwen3827b_on_a_single_rtx3090_131k_context_with/) |
| Uncensored low-cost / legacy — 2× P100 | `JonathanColetti` abliterated target, Q4_1 + Q8 head; special **llama.cpp-gp100** fork; DFlash2 / n-gram speculation | 55–61 tok/s cold/novel; 106–108 warm exact-reuse tok/s | This is specialized and explicitly not stock llama.cpp. The author cautions against quoting the 100+ warm-reuse number as general speed. [Model card and caveat](https://huggingface.co/fallentree/Qwen3.8-27B-Uncensored-GP100-GGUF) |
| Uncensored mixed INT4 — several GPUs | `Zynerji/...PristinelyUncensored...`, compressed INT4; vLLM; MTP k=2 | 87.6 (5090), 56.4 (4090), 50.4 (3090) tok/s at 4K; 16-GB cards could not start with MTP | Useful multi-GPU reference, but it is one community model-card author’s measurement. [Table and method note](https://huggingface.co/Zynerji/Qwen3.8-27B-PristinelyUncensored-HOMEUSER-16-24) |

## Configuration guidance

### A40 48 GB / RunPod (recommended here)

Keep the repo’s selected `philbert440/Qwen3.8-27B-Uncensored-Aggressive-GGUF` Q8_0 main model and Q8 MTP head, serving with `llama-server`/`llama-cli`.

- Fully offload target and MTP layers to CUDA; avoid CPU weight offload, which will dominate decode latency.
- Start at **64K context**, native MTP `n-max=3` or `4`, Flash Attention, then benchmark 1/2/3/4. The 5090 sweep favored 3, but acceptance and the best depth vary by GPU/workload.
- Use a quantized KV cache if memory/context requires it. In the controlled 5090 sweep, Q4_0 KV with MTP-2 was both faster (136.7 vs 125.5 tok/s) and 1.4 GB smaller than F16, but validate retrieval quality on your workload. [KV experiment](https://huggingface.co/Qwen/Qwen3.8-27B/discussions/112)
- For a shared endpoint, llama.cpp is fine for a few users; choose vLLM/SGLang when continuous batching, queueing, prefix caching, and high concurrency matter more than single-user simplicity.
- Keep the API private/authenticated. Uncensored behaviour does not remove the need for access control, rate limits, logging policy, and an application-layer tool-permission boundary.

### Maximum throughput server (new hardware)

1. **Hardware:** H200 first choice for the most complete evidence; RTX 5090/RTX PRO 6000 Blackwell for a lower-cost single-GPU path.
2. **Engine:** SGLang for the documented H200 DFlash2 result. The official cookbook says SM120/SM121 should use `--attention-backend flashinfer`; use a current FlashInfer that supports MTP prefill planning. [SGLang guidance](https://docs.sglang.io/cookbook/autoregressive/Qwen/Qwen3.8-27B)
3. **Weights:** Qwen BF16 for quality baseline; official FP8 where supported; NVFP4 for Blackwell throughput/VRAM. The NVFP4 BF16-head variant costs about 3.2 GB more at runtime than the packed-FP4 head. [Quantization details](https://docs.sglang.io/cookbook/autoregressive/Qwen/Qwen3.8-27B)
4. **Speculation:** use DFlash2 K=7/8 after measuring acceptance on representative prompts. The documented SGLang launch uses `--speculative-algorithm DFLASH`, the DFlash2 draft, and `--speculative-num-draft-tokens 8`. [Command](https://huggingface.co/z-lab/Qwen3.8-27B-DFlash2?library=transformers)
5. **Benchmark honestly:** report GPU, engine/version/commit, target/draft/checkpoint revision, quant and KV dtype, context limit, MTP/DFlash setting, prompt/output lengths, thinking state, concurrency, warm/cold state, TTFT, prefill rate, per-user decode rate, and aggregate output rate. Do not label a C4/C8 total as a single-user TPS.

## Normal versus uncensored model

| Choice | Use it when | Serving consequence |
|---|---|---|
| Official `Qwen/Qwen3.8-27B`, `-FP8` | You want the reference model, expected tool/vision/chat-template behaviour, and production reproducibility | Works with Transformers, vLLM, SGLang, and TokenSpeed according to the official card. [Official card](https://huggingface.co/Qwen/Qwen3.8-27B) |
| Community abliterated/uncensored GGUF | You explicitly need less refusal behaviour in a controlled private application | Usually best served by llama.cpp/Ollama/LM Studio. Measure quality, tool use, long-context recall, vision, and MTP compatibility yourself; “uncensored” is not a standardized training or safety claim. |

## Important evidence limits

- Qwen3.8-27B is **dense**, not the older Qwen3-30B-A3B MoE; do not use 30B-A3B throughput figures to size it.
- The model has an in-checkpoint MTP head and hybrid architecture (48 linear-attention layers plus 16 full-attention layers); both explain why long context and speculation matter unusually much. [Architecture](https://docs.sglang.io/cookbook/autoregressive/Qwen/Qwen3.8-27B)
- Thinking is enabled by default. Its output tokens count toward real user-visible latency/cost, so turn it off or lower effort only after evaluating task quality. The Qwen documentation shows that non-thinking can be set per request/template. [Qwen vLLM deployment guide](https://github.com/QwenLM/Qwen3/blob/main/docs/source/deployment/vllm.md)
- Community posts and model cards are valuable configuration evidence, not independent certification. The H200 DFlash2 result is the strongest controlled result located; the 5090 616 TPS vLLM claim requires custom patches and should be reproduced before purchase decisions.
