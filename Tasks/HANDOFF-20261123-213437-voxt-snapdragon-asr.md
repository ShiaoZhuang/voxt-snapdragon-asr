# Adreno 两组实机测速完成，已补 Hexagon SDK 下载重试与本地包支持

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-23 21:34:37 US/Pacific。

当前项目提交 `1d269b0dee4b3cce7b8f24f2583cff649daf2244`。写入本轮检查点前的 Git 状态：

```text
## experiment/real-qnn-replay...origin/experiment/real-qnn-replay
 M Handoff.MD
 M scripts/win-arm64/install_hexagon_sdk.ps1
```

最新实机照片（.local/snapdragon-device/1d269b0-result.jpg）显示 1d269b0，运行目录 20261124-132641-919-33768。SDK 下载报 curl exit 35，属于 TLS 握手阶段，本次未运行 GGML Hexagon，日志截图未给出握手失败的具体原因。Adreno 两组均通过同文本与 token 对照，Target-only 15 token / 3990 ms = 3.76 请求 tok/s，Q4 DFlash 15 token / 3642 ms = 4.12 请求 tok/s，本轮请求吞吐约提升 9.6%。同图较早的 340cd27 报告测得 3.53 与 4.11 请求 tok/s。

固定脚本保存 curl 的错误详情，下载失败后经 PowerShell 网络设置重试同一锁定发布包，遵循操作系统 TLS 验证。两路下载仍受阻时报告两种错误，提示同名发布包可放默认 Downloads 或项目 SDK 缓存目录，继续用锁定 SHA-256 校验后安装。采用小型 SDK 结构的测试归档及模拟网络错误，覆盖 curl 35、PowerShell 成功、双失败诊断与清理、缓存复用、Downloads 归档和 SHA-256 拒绝。测试日志见 .local/hexagon-sdk-verification/network/test.log。PowerShell 解析与 diff 检查通过。实际骁龙公司网络条件、SDK Windows 构建及 GGML TPS 待验证。

下一步：骁龙用原固定入口确认 SDK 下载重试或本地包安装，随后取得 GGML 的 DSP 执行证据和请求 tok/s。
