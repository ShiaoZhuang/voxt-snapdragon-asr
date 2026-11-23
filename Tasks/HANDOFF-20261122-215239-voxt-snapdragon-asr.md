# Windows ARM64 本机构建交接就绪，用户确认骁龙本已有 C++ 工具链

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-22 21:52:39 US/Pacific。

当前项目提交 `4a396111ae2556b9e7bc11379d121f55a87a5120`。写入本轮检查点前的 Git 状态：

```text
## veri/native-win-arm64
 M Handoff.MD
 M PLAN.md
 M README.md
 M Tasks/INDEX.md
 M Tasks/TASK-20261121-voxt-snapdragon-asr.md
 M scripts/prepare_benchmark.py
 M scripts/win-arm64/build_on_mac.sh
 M scripts/win-arm64/run_verify.ps1
 M sources.lock.json
?? Tasks/HANDOFF-20261122-213718-voxt-snapdragon-asr.md
?? scripts/win-arm64/build_native.ps1
```

- 用户确认此前自己的 GPU 推理版本可执行，本项目外部分发的验收程序多次触发拦截。最新 2026-11-23 13:39 +08:00 截图再次确认 Defender 拦 PowerShell 启动原 Veri 1 final-benchmark.exe。用户决定 Windows 现场从源码构建，且确认 C++ 工具链已安装。
- 新增 build_native.ps1，使用公司已批准工具从固定版本构建 Khronos loader、带 OpenCL 修复的 llama.cpp/Voxt 服务，以及 Voxt 的 Final Go runner。原模型/音频从现有 Veri 1 目录按哈希复用，本地产物单独记录 ARM64 PE、SHA、版本和 flags。构建流程不自动安装工具，不改系统安全配置。若仍遇策略阻止，遵循组织软件审批。
- 验证 Mac PowerShell 模拟 CMake 下的本机构建流程，包括带空格路径、固定 Git 版本、重新运行复用源码、真实 Go Windows ARM64 编译和 PE 清单。验收脚本 mock 四组通过，能在旧 EXE 不存在的资产目录复用测试资料，并拦截被篡改的本地 loader。Mac 全量和 Go-only 准备后的 Voxt 客户端源码已逐文件抽查一致。Windows clang/SDK 真实构建、公司策略和 Adreno 推理仍待实机。
- 更新 PLAN、README 和根目录验收交接，固定验收标签 `veri-1-native-arm64`，不发布新的预编译文件。

下一步：在获授权的 ARM64 Visual Studio Developer PowerShell 中构建并运行 Veri 快测，回传首条构建错误或四组报告
