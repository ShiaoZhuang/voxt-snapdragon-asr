# 已为 SDK 吊销检查失败上线即时显示与超时保护

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-23 22:54:13 US/Pacific。

当前项目提交 `4df97837d66f9a50ec5886dfc5a11d312789d9e7`。写入本轮检查点前的 Git 状态：

```text
## experiment/real-qnn-replay...origin/experiment/real-qnn-replay
 M Handoff.MD
 M scripts/win-arm64/current_handoff.ps1
 M scripts/win-arm64/install_hexagon_sdk.ps1
 M scripts/win-arm64/update_and_verify.ps1
 M scripts/win-arm64/verify_ggml_hexagon.ps1
 M scripts/win-arm64/verify_live_qnn.ps1
?? scripts/win-arm64/download_hexagon_sdk_web.ps1
```

用户实机报告 SDK curl 报 Schannel InitializeSecurityContext 无法检查证书吊销，父命令到退出才显示，等候约一小时。旧启动器异步保存 stdout/stderr 后调用无超时 WaitForExit，确实会隐藏阶段与错误。现有信息不能区分证书吊销检查不可用的具体网络原因，亦无本轮 HTP TPS 证据。

启动器现在实时转发阶段和 stderr，保留原始日志，每 30 秒标出等待中的阶段，验证阶段 35 分钟硬截止并尝试终止进程树。上一条路线已写入的结果会进入超时摘要。可用 -Route QnnLive 或 -Route GgmlHexagon 独立运行。旧启动器只更新测试工作树，用户本机需从已发布分支刷新根目录脚本一次。SDK 遇明确吊销状态无法核查立即显示、结束在线下载，保留 TLS 校验及本地发行包 SHA-256。一般网络失败仍可用 PowerShell 复试，两个客户端共用 8 分钟硬期限，curl 等待无中断来自外部进程在期限结束时终止。

本地 PowerShell 模拟受管理网络错误、curl 卡住、正常网络备选以及同名本地归档，见 .local/hexagon-sdk-verification/revocation/test.log。模拟 Git 和真实启动器验证运行中能见错误、超时进程树清理和已有结果保留，见 .local/test-handoff-live-errors.log。PowerShell 路线模拟验证单独运行两条路线以及 QNN 失败后继续 GGML，见 .local/live-qnn-handoff-watchdog.log。PowerShell 解析、git diff --check 完成。Windows 的证书链网络策略、真实进程树终止和骁龙 TPS 仍待设备确认。

下一步：刷新骁龙本地启动器后用 QnnLive 单测混合转录，GGML 用已获准的同名 SDK 归档继续验证。
