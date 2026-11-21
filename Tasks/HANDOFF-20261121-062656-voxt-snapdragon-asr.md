# 修正后端编译错误，继续原生 Mac 与 Windows ARM64 构建

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-21 06:26:56 US/Pacific。

当前项目提交 `d9bbc8f224b8dd18d2267d9e8b713e2238b6568c`。写入本轮检查点前的 Git 状态：

```text
## main
 M Tasks/INDEX.md
 M Tasks/TASK-20261121-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-062522-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-062623-voxt-snapdragon-asr.md
?? native/
?? patches/llama-voxt.patch
?? scripts/build_voxt_backend.sh
?? scripts/win-arm64/
```

- Mac 初次编译 failed，原因是误用了位于上游另一个编译单元的 string_lower。已加入本地 ASCII 大小写处理。
- Mac 重建 running，PID 73639，命令 ./scripts/build_voxt_backend.sh，.local/voxt-backend-rebuild.log/.exit。
- Windows ARM64 开始准备工具链，后续构建和退出条件见前一检查点。后端 OpenCL 模式指定 GPUOpenCL 设备，避免将 CPU 回退误计为 GPU 结果。

下一步：运行首条 Voxt Final，并按启动协议信息检查设备与回传
