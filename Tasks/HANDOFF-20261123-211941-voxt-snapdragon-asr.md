# 固定入口已接入 Hexagon SDK 自动安装与 TPS 对照，待骁龙实测

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-23 21:19:41 US/Pacific。

当前项目提交 `340cd273b6110526d1db6991a70b8c91e78ba260`。写入本轮检查点前的 Git 状态：

```text
## experiment/real-qnn-replay...origin/experiment/real-qnn-replay
 M Handoff.MD
 M scripts/win-arm64/build_native.ps1
 M scripts/win-arm64/verify_ggml_hexagon.ps1
 M sources.lock.json
?? scripts/win-arm64/install_hexagon_sdk.ps1
```

固定入口在查不到现有 SDK 时，从 llama.cpp 文档指定的发行版下载 Windows ARM64 Hexagon SDK Community Edition 6.7.0.0。GitHub 资产 900461020 字节，sources.lock.json 锁定 URL 与 SHA-256。写入项目构建目录，校验后解压至同卷临时目录，验证 CMake 文件、SDK 元数据和 Windows 编译器后再启用缓存目录。CMake 在同次运行获得 SDK 路径并由 SDK 元数据寻找工具链。复跑复用本机缓存；现有可用 SDK 优先。失败时保留 Adreno 两组测试。两侧都通过 token 对照和设备检查时按 Target-only 与 Q4 DFlash 分别计算请求吞吐倍率。现有 QNN 28 层可信结果已通过，固定入口继续聚焦完整音频。

本机下载实际 Windows ARM64 发行包，借助该包和 PowerShell 验证解压、重复运行命中缓存、损坏下载 SHA-256 拒绝和失败清理。用真实 Mac ASR 服务和模拟 DSP 记录验证四组报告、两组倍率、没有 Hexagon 构建时仍有 Adreno 基线、只有启动期 DSP 活动时无有效倍率。证据见 .local/hexagon-sdk-verification/{download,install-test,compare-test}.log。PowerShell 语法和 git diff --check 通过。实际 Windows 构建、受信任的 DSP 算子库加载和骁龙 TPS 仍待回传。

下一步：用骁龙原固定命令验证首次自动安装、四组请求 tok/s、同模式倍率及 DSP 请求执行证据。
