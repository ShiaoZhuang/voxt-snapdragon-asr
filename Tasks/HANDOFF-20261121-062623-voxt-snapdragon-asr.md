# 启动 Mac 到 Windows ARM64 的 OpenCL 交叉构建

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-21 06:26:23 US/Pacific。

当前项目提交 `d9bbc8f224b8dd18d2267d9e8b713e2238b6568c`。写入本轮检查点前的 Git 状态：

```text
## main
 M Tasks/INDEX.md
 M Tasks/TASK-20261121-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-062522-voxt-snapdragon-asr.md
?? native/
?? patches/llama-voxt.patch
?? scripts/build_voxt_backend.sh
?? scripts/win-arm64/
```

- Mac native build 仍 running，日志和退出门槛见前一检查点。
- 交叉构建 running，Mac PID 73378，命令 BUILD_JOBS=4 scripts/win-arm64/build_on_mac.sh，.local/windows-arm64-build.log 与 .local/windows-arm64-build.exit。锁定 LLVM-MinGW 20261117 和 Khronos 两项源提交。成功门槛为 ARM64 qwen3_asr_server.exe、OpenCL loader 和 ggml OpenCL 依赖齐全。

下一步：核对 Windows ARM64 EXE、DLL 依赖和首个上机验证矩阵
