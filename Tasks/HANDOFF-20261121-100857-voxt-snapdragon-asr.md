# 复测直接读取 Hugging Face 原版音频塔的可行性

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-21 10:08:57 US/Pacific。

当前项目提交 `46c00afa7771722eb61fc1e7d70b3e8904a88c4f`。写入本轮检查点前的 Git 状态：

```text
## main
```

- 用户卡在 mmproj.gguf 的 GitHub 下载。本轮确定旧选项仅改 Target，旧流程先下音频塔。上游 loader 的 OpenCL 路径已有将 BF16 张量以 F16 形式存储的代码，待验证该模型具体行为。
- Mac Metal 原始 BF16 音频塔评测 running，PID 4283，命令 build/final-benchmark -binary build/voxt-80023b29e6e1/bin/qwen3_asr_server -target .local/upstream-projector/models -eval .local/voxt-benchmark/Voxt/testdata/eval；第二组加固定 Q4 Draft。输出 .local/upstream-projector/results/，退出文件 .local/upstream-projector/results/exit。门槛为两组各 31 条并对照精度和逐 token。

下一步：核对 Mac 31 条输出，提供直接加载原版音频塔的下载选项
