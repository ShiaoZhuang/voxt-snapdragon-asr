# Voxt 骁龙实机验收

## 固定入口

旧启动器只更新独立工作树中的测试代码。要启用实时进度和超时保护，请在骁龙本仓库根目录刷新本地启动器一次：

```powershell
git fetch origin veri/native-win-arm64
if ($LASTEXITCODE -eq 0) { git restore --source=FETCH_HEAD -- scripts/win-arm64/update_and_verify.ps1 }
```

以后每轮在同一仓库根目录运行同一条命令：

```powershell
.\scripts\win-arm64\update_and_verify.ps1
```

启动器会显示正在运行的阶段、错误和每 30 秒的等待提示。验证阶段超过 35 分钟会退出并保留已有报告。可用 `-Route QnnLive` 单独跑混合转录对照，或用 `-Route GgmlHexagon` 单独跑 GGML。

当前固定入口先用同一条 `zh-plain-1.wav` 比较全 GPU DFlash 和 GPU + QNN HTP DFlash 的完整请求，再运行独立的 GGML Hexagon 验证。QNN 回放已通过，完整请求使用现有的 ARM64 QNN Python 环境。GGML Hexagon 构建受阻时会记录具体原因，并用本地 OpenCL 服务继续完成两组 Adreno 测速。请拍最后的 **VOXT SNAPDRAGON REPORT**，若一屏放不下，请分两张。无需重跑 31 条 CPU 基准。

## GPU + QNN HTP 转录

脚本先采集一批全 GPU 的八位置验证张量，为短上下文下的 28 层量化图确定形状与激活范围。采集和构建会话在计时前完成。两条测速请求均使用相同的模型、音频和 Q4 草稿配置。需要已有实机回放创建的 ARM64 QNN Python 环境。

混合路径用 GPU 执行音频预填充、Target prefill、草稿和不足八位置的批次。满八位置时，现有解码器把实际位置、token 和活动历史 KV 交给 QNN worker。worker 用 HTP 执行 28 层，主机处理 token embedding 和词表输出层。K/V、三处 Draft 辅助状态和 logits 写回原解码器，原接受、拒绝与回滚逻辑继续负责提交顺序。首次实现逐轮通过本地文件传输张量，全部等待、搬运、主机输出层和 QNN 执行时间计入请求 TPS。会话的固定历史容量按报告显示，超出容量会报对应错误。

报告只有在完整 token 序列和转录文本一致、服务与 worker 的满批轮数一致且有 QAIRT 执行记录时给出吞吐倍率。日志目录保存两个请求的计时、转录及 profiler 报告。

## GGML Hexagon 音频转录

脚本先查找现有 Hexagon SDK。找不到时下载 llama.cpp 指南列出的 Windows ARM64 Hexagon SDK Community Edition 6.7.0.0（约 900 MB），校验发布包的 SHA-256，解压到 `build/win-arm64-native/sdk/hexagon`，并在这次构建中传入 SDK 路径。下次会复用该目录。在线下载总预算为 8 分钟。Windows 无法确认 TLS 证书吊销状态时，脚本会立即显示原始错误并结束该下载；其他网络错误可在剩余预算内用 PowerShell 重试。默认 Downloads 或 SDK 缓存目录里的同名发布包可直接校验和解压。下载或构建受阻时，固定命令仍会用本机 OpenCL 构建测 Adreno。[上游 SDK 发行页](https://github.com/snapdragon-toolchain/hexagon-sdk/releases/tag/v6.7.0.0)

脚本在独立目录编译同时启用 OpenCL 和 Hexagon 的本地服务。Windows 的 GGML Hexagon 运行还依赖 NPU 驱动，以及设备信任的目录签名所覆盖的配套 DSP 算子库。已有的配套库可通过 `GGML_HEXAGON_LIBHTP_DIR` 配置。已有签名环境可用上游的 `HEXAGON_HTP_CERT` 参与构建。[固定版本的上游 Windows 说明](https://github.com/ggml-org/llama.cpp/blob/e412c6f468b7b9e0f16f2540244236f8ad68e9ae/docs/backend/snapdragon/windows.md)

对同一条 `zh-plain-1.wav`，脚本分别运行 Adreno 和 HTP0 Target，每种设备各测 Target-only 和 Q4 DFlash。音频投影及可选草稿都在 Adreno。每个测试启动独立服务，比对 Adreno Target-only 的完整 token 序列和转录文本。GGML Hexagon 还要求请求开始后出现有非零周期的 DSP 算子记录。GGML 调度器可能将部分计算放在主机上。两侧都通过时，报告会按同一模式给出 Hexagon / Adreno 请求吞吐倍率。每个测试的 `.txt` 保存原始日志，`.metrics.json` 保存文本、token 和计时。摘要中的 request tok/s 使用生成 token 数（排除 EOS）除以 HTTP 请求时间，包括音频预填充和解码，排除启动加载时间。HTP 测试打开了设备 profiling。

## 完整 Target 回放

内部工作脚本 `current_handoff.ps1` 的 `-FullReplay` 模式仍可运行完整回放。流程从公开 `zh-plain-1.wav` 捕获真实八位置验证批次，串起 28 个独立 HTP 层会话，把上一层的隐藏输出传给下一层。每层复用 Adreno 采集的历史 K/V，计算当前八位置的 K/V 与隐藏输出。CPU 运行小批次 QDQ 数值对照。HTP 禁用 CPU fallback，各层都检查 QAIRT 执行记录。最后用主机原 Q8_0 词表投影比较 logits、top-1 和 DFlash 三处辅助输入。

每层需要 CPU 对独立参考的相对 L2 ≤0.25%，HTP 对同输入 CPU 的相对 L2 ≤0.5%，最大误差分别 ≤参考峰值的 1% 和 2%。整批次还需要八个 top-1 全部匹配。第 27 层保存 attention 残差相加前后的状态和 FFN 各阶段。原生重建采用 5% 相对 L2 门槛，在有完整采集时逐阶段以原生输入检查，同时报告累计误差。若原生重建超出门槛，脚本继续采集 HTP 和 logits 结果，并列出超限项。若仅末层 ffn_down 超过 5% 且数值有限，允许在完整链八位置 top-1 一致时通过；缺层、超时、无执行证据和非有限数值仍失败。

先用原生输入单测第 27 层，再运行串联回放。每层 HTP 使用独立进程，最多等待 45 秒。若一层无法执行，后续层用下一份原生激活继续诊断，同时保留已有结果。串联验证的启动预算为 900 秒，整段回放由 1050 秒保护。报告在超时时标出最后记录的阶段及已保存的层数，日志保留单层 QNN 初始化、执行、profiling 和清理阶段。

各层中位数之和由每层三次热态运行得出。端到端时间、原生 KV 跨轮提交和连续转录属于下一阶段。每层数据和完整结果留在 `Logs` 指向的 `target-replay` 目录。

## Hexagon HTP 依赖

固定脚本从现有项目环境、PATH、Windows 注册信息和 `py` 启动器中查找标准版 Windows ARM64 CPython 3.11–3.14。屏幕摘要会列出已检查的解释器路径、平台和版本。若显示 `No compatible Python found`，请安装公司允许使用的 Windows ARM64 CPython 3.14，再运行同一条验证命令。[Python 3.14.10 官方下载页](https://www.python.org/downloads/release/python-31410/)

脚本会创建或复用 `.local` 下的隔离环境，从本机配置的 pip 软件源安装 `tools/qnn-probe/requirements-win-arm64.txt` 中锁定的包。依赖安装失败时，原始输出在 `qnn-dependencies.stdout.log` 和 `qnn-dependencies.stderr.log`。[QNN EP v2.8.0 安装说明](https://github.com/onnxruntime/onnxruntime-qnn/tree/v2.8.0#install)

新加的 `gguf` 包仅用于读取本地原始权重。模型、捕获数据、临时 ONNX 和日志都留在本机。

## 骁龙本从源码构建与验收

在骁龙本的 PowerShell 中打开源码仓库根目录。脚本会使用已有的 Visual Studio ARM64 环境、CMake、Ninja 和 Python。需要公司批准的 Clang，可使用 Visual Studio 的 **C++ Clang Compiler for Windows** 组件。锁定的 Windows ARM64 OpenCL 后端要求 Clang，Visual Studio 提供 Windows 链接所需的头文件和库。[llama.cpp 构建要求](https://github.com/ggml-org/llama.cpp/blob/e412c6f468b7b9e0f16f2540244236f8ad68e9ae/docs/backend/OPENCL.md#L196)

```powershell
.\scripts\win-arm64\build_native.ps1 -BackendOnly
.\scripts\win-arm64\probe_opencl_startup.ps1 -NativeBuildDirectory .\build\win-arm64-native -Transcribe
```

只检查工具时运行 `build_native.ps1 -BackendOnly -ToolchainCheck`。后端快测复用已有 Veri 1 模型和 `zh-plain-1.wav`，不用 Go。成功会记录 `Transcription probe: PASS`，回传 `Report saved to:` 指向的文本文件即可。

安装公司批准的 Go 1.27.1+ 后，从同一源码标签执行完整快测：

```powershell
.\scripts\win-arm64\build_native.ps1
.\scripts\win-arm64\run_verify.ps1 -NativeBuildDirectory .\build\win-arm64-native -OpenCLOnly -Quick
```

构建在骁龙本生成后端、OpenCL loader 和评测器。继续使用 `dist\voxt-snapdragon-veri-1` 的现有模型、评测集和资产清单。若资产在其他目录，用 `-InstallDirectory` 指向该目录。复验通过条件为两组 OpenCL 快测 PASS，DFlash 有候选被接收并与 Target-only 逐 token 一致。需要复测 CPU 时，可单独调用 `run_verify.ps1` 并省略 `-OpenCLOnly`。

回传 `Results:` 目录内的 `verify_report.md` 和 `verify_stats.json`。若构建失败，回传第一条工具错误及其上下文。若公司策略拦截本机构建的程序，按 IT 的软件审批流程处理。

## OpenCL 启动修复复验

在已安装 Veri 1 的骁龙本上，从源码仓库根目录运行：

```powershell
git fetch origin tag veri-1-opencl-fix
git switch --detach veri-1-opencl-fix
.\scripts\win-arm64\fetch_veri1.ps1 -OpenCLFixOnly
.\scripts\win-arm64\run_verify.ps1 -OpenCLFix -Quick
```

只下载约 6 MB 的 ARM64 运行时更新，复用已安装的模型、依赖和评测集。脚本独立校验新 EXE 的 SHA-256，将它和 Veri 1 原版 EXE 并排放置。可通过 `-Destination` 和 `-InstallDirectory` 分别指定自定义的 Veri 1 安装目录。

通过条件为四组快测都显示 PASS，两个 OpenCL 模式完成转录，OpenCL DFlash 有候选被接收且与 OpenCL Target-only 逐 token 一致。先回传 `Results:` 目录里的 `verify_report.md` 和 `verify_stats.json`。失败时一并回传该组 `.log`。

## 排查 OpenCL 启动崩溃

如果 CPU 快测通过，但 OpenCL 在读取 `target.gguf` 后以 `0xC0000005` 退出，在源码仓库根目录运行：

```powershell
.\scripts\win-arm64\probe_opencl_startup.ps1
```

探针复用 `dist\voxt-snapdragon-veri-1` 中已安装的运行时和模型，可用 `-InstallDirectory` 指定其他位置。它仅启动一次 OpenCL Target，记录完整 stderr、退出码和过去两天相关的 Windows 应用崩溃事件。把 `Report saved to:` 指向的文本文件发回即可。整个探针无需下载文件或跑评测集。

## 运行验收

在 Windows 11 ARM64 的骁龙 X Elite 笔记本上验证 Voxt 本地转录后端。整个交接目录含原生 EXE、OpenCL loader、模型和公开评测集。需要系统已有 Qualcomm Adreno OpenCL 驱动。目录中的 `verify_manifest.json` 记录准确源码版本和各文件的 SHA-256。

1. 将整个 Veri 1 目录复制到骁龙本并在其根目录打开 PowerShell。
2. 运行 `.\scripts\win-arm64\run_verify.ps1`。如需先做快速探针，加 `-Quick`。
3. 将脚本输出路径下的 **verify_report.md** 和 **verify_stats.json** 带回 Mac。失败时也回传这两个文件。

完整验收会分别在 Oryon CPU、Adreno OpenCL 上跑 Target-only 与固定 Q4 Draft，共四组 31 条。每组识别错误率需 ≤3.4%，词典命中 ≥7/10。Draft 全集平均接受 ≥3.0，三个干净句的平均接受 ≥5.3。同一设备逐 token 对齐 Target-only。耗时用于比较与定位，报表分开记录 Draft、Target 验证和 Context。实机使用阶段仍是通过公开 WAV 驱动的 Voxt 协议后端。


通过 GitHub 获取 Veri 1 时，请在源码仓库根目录运行新版 `.\scripts\win-arm64\run_verify.ps1 -Quick`。它会直接使用已组装的官方安装目录，也可以用 `-InstallDirectory` 指向自定义安装目录。
