# Third-party notices

LocalFlow integrates, without claiming authorship:

- FluidAudio — https://github.com/FluidInference/FluidAudio — Apache-2.0. Its pinned package contains additional dependency notices.
- MLX Swift and MLX Swift LM — https://github.com/ml-explore/mlx-swift and https://github.com/ml-explore/mlx-swift-lm — MIT. swift-transformers — https://github.com/huggingface/swift-transformers — Apache-2.0.
- Gemma 4 E2B (default editor) — Google, https://huggingface.co/google/gemma-4-e2b-it — Gemma Terms of Use. 4-bit MLX conversion: https://huggingface.co/mlx-community/gemma-4-e2b-it-4bit. Weights are fetched from the conversion repository at a pinned revision; Google's use restrictions apply to the model and its outputs, while this repository's code is MIT.
- Qwen3-4B-Instruct-2507 (alternative editor) — Qwen Team, https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507 — Apache-2.0. 4-bit conversion: https://huggingface.co/mlx-community/Qwen3-4B-Instruct-2507-4bit.
- Parakeet TDT v3 — NVIDIA, https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 — CC-BY-4.0. CoreML conversions by FluidInference, https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml. Conversion/quantization modifies the original artifacts. The conversion card's metadata and prose disagree about the license; retain the upstream CC-BY attribution.
- Speaker diarization: Pyannote Community-1, WeSpeaker and FluidInference CoreML conversion, https://huggingface.co/FluidInference/speaker-diarization-coreml — CC-BY-4.0 attribution to the upstream authors; see the model card citations. CoreML conversion modifies the upstream artifacts.
- SQLite — public domain, provided by macOS.

Weights are downloaded from their publishers at pinned revisions; they are not committed to this repository. Transitive package licenses remain with their source packages. No endorsement by any upstream author is implied.
