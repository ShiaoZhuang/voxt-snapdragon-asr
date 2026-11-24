# QNN 28 层实机回放通过，GGML Hexagon 尚待定位或安装 SDK

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-23 21:05:30 US/Pacific。

当前项目提交 `6acdd4f5aec3d87a73dcd6d103c952ef771b38b5`。写入本轮检查点前的 Git 状态：

```text
## experiment/real-qnn-replay...origin/experiment/real-qnn-replay [ahead 1]
 M Handoff.MD
 M scripts/win-arm64/build_native.ps1
 M scripts/win-arm64/current_handoff.ps1
 M scripts/win-arm64/qnn_handoff.ps1
 M scripts/win-arm64/verify_ggml_hexagon.ps1
?? scripts/win-arm64/find_hexagon_sdk.ps1
?? scripts/win-arm64/verify_replay_assets.ps1
```

实机报告 7243740，运行目录 20261124-112809-719-33768。Target replay: PASS。HTP 28/28，CPU 数值对照 28/28；672 个 QAIRT 执行事件，28 层热态中位数之和 81.59 ms。八位置完整 HTP 链与 Adreno 的 top-1 一致 8/8，logits 相对 L2 1.960%，末层 ffn_down 3.256%。此外三处 DFlash 辅助输入 L2 为 2.006%、1.621%、1.299%。GGML Hexagon 在编译前报告 Hexagon SDK unavailable，未取得 GGML 设备或请求速度结果。日志不足以判断 SDK 未安装还是当前脚本未找到。

本轮固定入口默认只做同音频转录。保留显式 FullReplay 用于重跑 QNN 检查。扩展 SDK 查找至当前进程、用户及系统设置、工具链目录上级以及标准安装目录；找不到时报告已检查位置。GGML 构建失败仍尝试在骁龙本编译普通 OpenCL 版，完成两组 Adreno 请求基线，同时保留失败状态。两种入口继续核验模型及评测音频的哈希。

本机 PowerShell SDK 定位测试覆盖缺失、失效路径、版本目录排序、显式设置及工具链反推。通过真实 Mac 服务、样本与模拟硬件标记验证四组正常运行、缺 SDK 时两组 Adreno 仍完成，以及仅启动期有 DSP 事件时拒绝验收；证据见 .local/test-sdk-discovery.ps1 与 .local/ggml-sdk-followup-tests.log。GGML Hexagon 的 Windows 编译及真机转录仍待回传。

下一步：骁龙固定入口测同一音频的 Adreno 与 Hexagon 请求 tok/s；若仍缺 SDK，按报告的查找路径配置 6.7+ 后复测。
