# Voxt Snapdragon ASR

Windows ARM64 本地推理移植。开发与实机验收顺序见 [PLAN.md](PLAN.md)，当前工程状态见 [Tasks/INDEX.md](Tasks/INDEX.md)。

## 复现 Mac 基准

以下命令从仓库根目录运行。需要 Python 3.11+、Voxt 指定的 Go 工具链，以及能运行的 Mac MLX 基准二进制。 `patches/voxt-mlx-baseline.patch` 是在锁定 SGLang-Omni 提交上重建 Mac 基准的改动。准备脚本另在临时副本中记录 Voxt 实际收到的 SSE 完成事件。

```sh
python3 scripts/prepare_benchmark.py --voxt-repo ../sglang-omni --destination .local/voxt-benchmark
mkdir -p build
(cd .local/voxt-benchmark/Voxt && go build -mod=readonly -o ../../../build/final-benchmark ./cmd/final-benchmark)
scripts/run_mlx_baseline.sh /path/to/qwen3_asr_server .local/mac-baseline
python3 benchmark/summarize.py .local/mac-baseline
```

`VOXT_MODEL_ROOT` 可覆盖默认 Voxt 模型库。各模式输出 31 条 `main zh`，另含一次预热和五条无词典对照。JSONL 保留逐段 SSE 和 Voxt 拼接后的文本。报告中的主指标只汇总 31 条主评测。原始输出保存在忽略目录 `.local/`。

## 复现 llama.cpp 探针

Mac 用 CMake、C++ 编译器和 jq 构建，用 Python 环境载入锁定版本的 GGUF 库。下列示例从 Voxt 模型库获得已通过 SHA-256 的 Draft 权重。

```sh
scripts/build_upstream_probe.sh
scripts/fetch_probe_models.sh
python3 -m venv .local/gguf-python
.local/gguf-python/bin/pip install .local/llama-e412c6f4/gguf-py

scratch=.local/gguf-probe
draft_snapshot="/path/to/Qwen3-ASR-1.7B-dflash/snapshot"
.local/gguf-python/bin/python scripts/convert_asr_models.py projector \
  "$scratch/mmproj-Qwen3-ASR-1.7B-bf16.gguf" "$scratch/mmproj-Qwen3-ASR-1.7B-f16.gguf"
.local/gguf-python/bin/python scripts/convert_asr_models.py draft "$draft_snapshot" \
  "$scratch/draft-bf16.gguf" --target "$scratch/Qwen3-ASR-1.7B-Q8_0.gguf"
build/llama-probe/bin/llama-quantize "$scratch/draft-bf16.gguf" "$scratch/draft-q4_0.gguf" Q4_0

python3 scripts/probe_transcription.py \
  --wav .local/voxt-benchmark/Voxt/testdata/eval/zh-plain-1.wav \
  --projector "$scratch/mmproj-Qwen3-ASR-1.7B-f16.gguf" \
  --draft "$scratch/draft-q4_0.gguf" --output .local/probe-draft
```

省略 `--draft` 测 Target-only，加 `--cpu` 测 CPU。探针记录上游命令、服务器日志和 SSE；Voxt 托管、停止规则和完整元数据由移植服务实现。F16 音频塔保留原 mmproj 的 F32 bias、归一化和位置参数。

## Voxt 托管后端和 Windows ARM64

Mac 可用 `scripts/build_voxt_backend.sh` 构建 `qwen3_asr_server`。脚本在独立的上游源码副本中应用 `patches/llama-voxt.patch`。模型目录分别提供 `target.gguf`、`mmproj.gguf`；加载草稿时通过 `--draft-model-path` 传入包含 `draft-4.gguf`、`draft-6.gguf` 或 `draft-8.gguf` 的目录。位数对应 Q4_0、Q6_K 或 Q8_0，首轮的包包含 Q4_0。评测器调用同一 EXE 和 Voxt 现有的 Final 请求。设置 `VOXT_ASR_TRACE=1` 可在 SSE 元数据里采集实际输出 token 及前三轮的候选与验证结果。

在 Mac 上运行 `scripts/win-arm64/build_on_mac.sh` 构建 Windows ARM64 + Adreno OpenCL，再运行 `python3 scripts/win-arm64/package_on_mac.py dist/voxt-snapdragon-veri-1` 组装可拷贝的离线目录。运行目录可含空格。实机命令与回传文件见 [Handoff.MD](Handoff.MD)。
