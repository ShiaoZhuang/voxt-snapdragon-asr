# Veri 1 原生 Windows ARM64 包已就绪，等待骁龙实机结果

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-21 06:34:43 US/Pacific。

当前项目提交 `8da314d34c147e9fd37117e61e77a191f6e34c64`。写入本轮检查点前的 Git 状态：

```text
## main
 M Tasks/TASK-20261121-voxt-snapdragon-asr.md
```

- Veri 交付代码为 tag veri-1，commit 8da314d34c147e9fd37117e61e77a191f6e34c64。包为 dist/voxt-snapdragon-veri-1，约 2.9 GiB。manifest 的 50 个文件逐 SHA-256 回读通过，内含 29 个 WAV 和两条拼接定义。六个 EXE/DLL 均为 ARM64 PE32+，后端导入 OpenCL.dll。Windows 最终构建 .local/windows-arm64-package-build.exit=0。
- 实际 Mac 协议检查通过：ready 端口和 PID、SSE 心跳和 [DONE]、自动识别语言、无前缀正文、非流式 JSON、max_new_tokens、坏参数 400、stdin shutdown。日志 .local/protocol-native.log。Mac Metal 两组各 31 条、逐 token 结果见上一记录。
- 正式 PowerShell 脚本在 Mac 解析并回放四组 31 条 JSONL 成功，生成两个回传文件。本轮无可连接的 Windows ARM64 实机，Windows 驱动、OpenCL 运行和真实性能仍未验证。
- 当前包用固定 Draft；实机之后继续自适应回退、核对设备瓶颈，以及后续 NPU/Windows UI。公开 GitHub 目前无配置 remote 或已授权的仓库创建入口。实机包可先离线拷贝。
- 相邻 sglang-omni 分支、HEAD 和既有修改不变。无运行作业。

下一步：在骁龙本运行 Handoff.MD 的 run_verify.ps1 并回传 verify_report.md 与 verify_stats.json
