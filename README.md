# Voxt Snapdragon ASR

Windows ARM64 本地推理移植。开发与实机验收顺序见 [PLAN.md](PLAN.md)，当前工程状态见 [Tasks/INDEX.md](Tasks/INDEX.md)。

## 骁龙本桌面听写

在已通过原生 HTP 验证的 Windows ARM64 机器上，从仓库根目录运行 `.\scripts\win-arm64\update_and_verify.ps1` 即可安装并打开固定版 Voxt。以后双击桌面的 **Voxt Snapdragon Pilot 1**，在输入框按 **Ctrl+Alt+Space** 开始录音，再按一次结束并回填。详见 [Windows 用户测试说明](Handoff.MD)。

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

公司骁龙本每轮运行 `scripts/win-arm64/update_and_verify.ps1`。它同步最新验证提交，运行该提交指定的构建和测试步骤，并在屏幕上打印结果摘要。首次设置和回传说明见 [Handoff.MD](Handoff.MD)。

## 从 GitHub 获取 Veri 1

在骁龙本使用 PowerShell。克隆只取源码，下载脚本会从同一个 GitHub 仓库的 Release 组装程序、评测音频和模型，再逐个核对 SHA-256。已校验的模型可在重跑时复用。网络需要能跟随 GitHub Release 的资产下载重定向。

```powershell
git clone https://github.com/ShiaoZhuang/voxt-snapdragon-asr.git
cd voxt-snapdragon-asr
.\scripts\win-arm64\fetch_veri1.ps1
.\scripts\win-arm64\run_verify.ps1 -Quick
```

快速检查通过后，用同一路径运行 `run_verify.ps1`，省略 `-Quick`。 已安装 Veri 1 时，`git pull --ff-only` 后可从仓库脚本直接复用原安装。自定义安装目录可通过 `-InstallDirectory` 指定。回传输出目录的 `verify_report.md` 和 `verify_stats.json`。

如果骁龙本可以访问 Hugging Face，可以用 `fetch_veri1.ps1 -TargetSource HuggingFace` 从上游下载字节相同的 Q8_0 Target。程序包、F16 音频编码器和 Q4 Draft 仍由 GitHub Release 提供。两条路径使用相同 SHA-256，已经校验通过的文件自动复用。未完成的 GitHub 分片和 Hugging Face 下载进度各自保留。

若卡在下载 `mmproj.gguf`，可加 `-ProjectorSource HuggingFace` 取上游 BF16 音频编码器，再使用 Release 中的原生 ARM64 工具在本地一次性转成原 Veri 1 FP16 文件。脚本只有在转换产物的 SHA-256 与原 F16 一致时才安装，推理精度与验收基线保持一致。已下载的原版 BF16 或已安装的 FP16 都可以复用。`-TargetSource HuggingFace` 可同时使用。

转换器源代码在 `tools/projector-fp16`。布局配方包含原文件数据区起点、原 Veri 1 FP16 的 GGUF 元数据头及要转换的 BF16 张量区间。可用 `scripts/win-arm64/make_projector_layout.py` 对照两个同版本 GGUF 重建该配方。


## 提交与实机迭代

小步修复在专题分支上提交，通过同一个 GitHub PR 交给实机验证。需要连续试错时，可以单独检出该分支。一个主题通过后用 Squash and merge 合入 `main`，PR 保留分支的提交、讨论和结果。`Veri:` 留给正式交接版本。已经公开的提交和验收 tag 继续作为原交付的定位点。
