# Mac 新后端通过 31 条逐 token 对照，Windows 包进入组装

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-21 06:33:50 US/Pacific。

当前项目提交 `d9bbc8f224b8dd18d2267d9e8b713e2238b6568c`。写入本轮检查点前的 Git 状态：

```text
## main
 M README.md
 M Tasks/INDEX.md
 M Tasks/TASK-20261121-voxt-snapdragon-asr.md
?? Handoff.MD
?? Tasks/HANDOFF-20261121-062522-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-062623-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-062656-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-062753-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-062913-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-062933-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-063050-voxt-snapdragon-asr.md
?? native/
?? patches/llama-voxt.patch
?? scripts/build_voxt_backend.sh
?? scripts/win-arm64/
```

- Mac Metal 新后端两组 31 条跑完（.local/native-matrix.exit=0），Target-only 与 Q4 Draft 完整 token 序列 31/31 一致，错误率均为 30/946=3.171%，词典 7/10。固定 Q4 接受 730/1547，221 轮，avg_accept=3.303，clean=6.00，Target 验证占三段约 65.8%。从同一 Go 客户端获得的结果保存在 .local/native-matrix。
- Windows ARM64 带 trace 的 OpenCL 后端构建通过，见 .local/windows-arm64-trace-v2.exit。禁用可选 Web UI 远程资产后，交付版 Windows 增量构建 running，PID 87695，.local/windows-arm64-package-build.log/.exit。
- PowerShell 7.7 在 Mac 语法验证 passed。使用同一 31 条输出回放，四组报告、token 对照和结论均生成；这验证了报告脚本，不是骁龙实机结果。

下一步：完成原生协议检查、可复现产包和 Handoff.MD
