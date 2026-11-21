# Windows ARM64 后端已链接，继续带逐轮追踪的构建

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-21 06:29:33 US/Pacific。

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
?? native/
?? patches/llama-voxt.patch
?? scripts/build_voxt_backend.sh
?? scripts/win-arm64/
```

- Windows OpenCL 后端 v2 构建通过，.local/windows-arm64-v2.exit=0。file 确认 qwen3_asr_server.exe 和 OpenCL.dll 都是 Aarch64 PE32+，导入包括 OpenCL、libc++ 和 libunwind。
- 新版追踪构建第一次复用了旧 CMake 缓存而失败。已让默认输出目录随补丁哈希变化，并保留显式输出目录设置。
- 新版 Windows build running，PID 82360，命令 BUILD_JOBS=6 scripts/win-arm64/build_on_mac.sh，.local/windows-arm64-trace-v2.log/.exit。最新 Mac build 见 .local/voxt-backend-trace.log/.exit。

下一步：校验新版后端的 PE 依赖并准备一键验收
