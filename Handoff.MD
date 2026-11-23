# Voxt 骁龙实机验收

## 固定入口

在骁龙本仓库根目录首次获取启动脚本：

```powershell
git fetch origin tag veri-1-auto-handoff
git switch --detach veri-1-auto-handoff
```

以后每轮在同一仓库根目录运行同一条命令：

```powershell
.\scripts\win-arm64\update_and_verify.ps1
```

本轮验证 **同一个真实八位置批次的 FFN 和 attention**。脚本同步 `veri/native-win-arm64`，复用现有模型和公开 `zh-plain-1.wav`，编译 ARM64 后端并在 Adreno 上采集第 0 层。FFN 使用逐输出通道 U8 权重、U16 激活。Attention 使用实际 post-RoPE query、缓存中的 K/V 和每个 query 的因果掩码，CPU 和 HTP 分别回放 FP16 分组注意力。两组都禁用 HTP 的 CPU fallback。首次构建可能需要几分钟。

结束后拍回整段 **VOXT SNAPDRAGON REPORT**。两组都会输出误差、QAIRT 后端执行事件、进程状态和延迟。FFN 保留原有门槛。Attention 先检查每个 query 比前一个多看到一个 KV 位置，并与 Adreno 捕获输出核对。CPU 对独立参考的相对 L2 门槛为 0.25%，HTP 对通过的 CPU 与独立参考均为 0.5%，峰值误差门槛分别为参考峰值的 1% 和 2%。

Attention CPU 首先回放 FP16 图并报告数值。若这组失败，自动用相同 FP16 输入输出、内部 FP32 计算的 CPU 图复核。两条 CPU 路径都失败时，HTP 仍与独立参考比较并保存执行证据，总体报告保留 CPU 对照未通过的状态。Attention 使用捕获后的只读 KV 视图，连续解码的 KV 提交与回滚进入后续验证。完整文件在 `Logs` 指向的目录内。

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
