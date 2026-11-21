# Mac 的真实 Voxt 后端开始跑全量 31 条对照

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-21 06:30:50 US/Pacific。

当前项目提交 `d9bbc8f224b8dd18d2267d9e8b713e2238b6568c`。写入本轮检查点前的 Git 状态：

```text
## main
 M Tasks/INDEX.md
 M Tasks/TASK-20261121-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-062522-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-062623-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-062656-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-062753-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-062913-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-062933-voxt-snapdragon-asr.md
?? native/
?? patches/llama-voxt.patch
?? scripts/build_voxt_backend.sh
?? scripts/win-arm64/
```

- Mac 带 trace 的后端已构建通过。Metal 的 Target-only 与固定 Q4 真实客户端评测 running，PID 87514，命令 build/final-benchmark -binary build/voxt-<patch>/bin/qwen3_asr_server -target .local/backend-weights -eval .local/voxt-benchmark/Voxt/testdata/eval，第二组加 -draft，输出 .local/native-matrix/，退出文件 .local/native-matrix.exit。两组各 31 条为成功门槛。
- Windows 新版构建日志和退出文件见前一记录。

下一步：比较两组逐 token 序列及接受门槛，确认上机包是质量验收还是排错用途
