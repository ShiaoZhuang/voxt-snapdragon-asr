# 骁龙本 OpenCL Target-only 单条转录实机通过，下一轮切换到 Q4 DFlash 同样本对照

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-22 23:26:45 US/Pacific。

当前项目提交 `5ebe5ed3a95b0111b98aa7d3b0d16e3343fd136c`。写入本轮检查点前的 Git 状态：

```text
## veri/native-win-arm64...origin/veri/native-win-arm64
 M Handoff.MD
 M scripts/win-arm64/current_handoff.ps1
 M scripts/win-arm64/probe_opencl_startup.ps1
```

- 2026-11-23 15:07:51 +08:00 的新实机报告，提交 5ebe5ed3a95b0111b98aa7d3b0d16e3343fd136c。Windows ARM64 在骁龙本完成 Clang/CMake 原生构建，启动 OpenCL Qwen3-ASR-1.7B Target-only 后完成 zh-plain-1，HTTP 200、15 个生成 token、请求 Wall ms 3843、正常退出 0。转录和 Mac 同一条的文本一致。本次没有 DFlash 实机数据。
- 固定入口的下一轮任务复用原模型和 WAV，校验四个文件 SHA-256，然后分别启动 OpenCL Target-only 与 OpenCL Q4 DFlash。采集 GPU 层 offload、请求墙钟、候选接收数、avg_accept/avg_step/accept_rate、Draft/Target/Context 毫秒与占比。要求 DFlash 有真实接收并输出完全相同的 token ID 和文本。两个原始探针日志包含 SSE 和前三轮候选轨迹。不需要 Go。
- Mac Metal 使用真实模型和原 WAV 跑了同一对照脚本，Target 701 ms、Q4 DFlash 308 ms、14/14 接收、2 轮、逐 token 相同。另验证文本相同但 token 不同仍失败，且已打印 profiling。旧启动探针 mock 与 PowerShell 语法检查通过。Adreno DFlash 仍待实机运行。

下一步：同一固定入口运行 OpenCL Target-only 与 Q4 DFlash，回传接收指标、分段耗时和逐 token 对比结果
