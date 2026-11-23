# 骁龙本已找到 ARM64 Visual Studio、CMake、Ninja 和 Python，只待 Clang 后可构建并试跑单条 OpenCL

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-22 22:08:36 US/Pacific。

当前项目提交 `e79d94d45df57566d3d77bc12e87ac792d41c095`。写入本轮检查点前的 Git 状态：

```text
## veri/native-win-arm64...origin/veri/native-win-arm64
 M Handoff.MD
 M scripts/win-arm64/build_native.ps1
 M scripts/win-arm64/probe_opencl_startup.ps1
 M scripts/win-arm64/run_verify.ps1
```

- 最新照片显示标签 veri-1-native-toolchain（e79d94d）正确，Visual Studio 2026 Developer PowerShell v18.6.1 已启动，目标 arm64。git、配套 CMake/Ninja、Python 3.14 已找到。仅 clang、clang++、go 未发现，未开始实际编译。
- 核对固定 llama.cpp e412c6f4 的 docs/backend/OPENCL.md，Windows ARM64 OpenCL 明确要求 Clang；MSVC cl.exe 路径没有上游支持，保留已有 VS SDK、头文件和库。新增 -BackendOnly 取消该模式的 Go 依赖，只拉后端及 Khronos 源码。完整评测仍保留 Voxt Go runner。
- probe_opencl_startup.ps1 新增 -NativeBuildDirectory 和 -Transcribe，验证本机 server 与 loader SHA-256，使用原数据 zh-plain-1.wav 向环回接口发出 multipart 请求，记录 SSE 完成、文本、元数据、耗时及崩溃事件。
- Mac 上通过模拟 CMake 的 backend-only/no-Go 和完整流程、既有 startup mock 和四组报告 mock。真实 Mac Metal 服务加真实 WAV 返回 HTTP 200，完整 SSE、15 tokens、0.958 秒、退出码 0；另确认替换 loader 后在启动前拒绝。Windows PowerShell 5.1、Clang 构建和 Adreno 推理待实机。
- 交接标签 `veri-1-native-backend` 只交源码和脚本，复用已有模型，无额外 EXE 资产。

下一步：使用公司批准的 Clang，在骁龙本构建 BackendOnly 并回传单条 OpenCL 转录报告，随后补 Go 运行完整快测
