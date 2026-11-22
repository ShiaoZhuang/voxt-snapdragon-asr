# 骁龙 CPU 两组单条快测通过，Adreno 两组在 Target 初始化时发生 0xC0000005，诊断分支已发布

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-21 23:18:33 US/Pacific。

当前项目提交 `09e65bfd39ef8f1333f89a7ad0400e7d5e8accfe`。写入本轮检查点前的 Git 状态：

```text
## diagnose/veri-1-opencl-startup...origin/diagnose/veri-1-opencl-startup
 M Tasks/INDEX.md
 M Tasks/TASK-20261121-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-230652-voxt-snapdragon-asr.md
```

- Windows Veri 1 实机报告 `verify-20261122-150236-135`（截图，模式 smoke）确认 ARM64 架构、清单 SHA-256 通过，Adreno X1-85 驱动 31.0.133.1，设备名 GPUOpenCL。运行时来源为发布清单中的 8da314d，llama.cpp e412c6f4。
- Oryon Target-only 和 Q4 DFlash 的 `zh-plain-1` 均为 0/23，wall 分别 9044 ms 和 9836 ms。DFlash 14/14 候选、2 轮、avg_accept 7.00、avg_step 8.00、0 token mismatch。Draft / Target / Context 为 1060.39 / 121.06 / 12.62 ms/round。该结果只覆盖一条短句，全集质量和加速待测。
- `opencl-target-only.log` 与 `opencl-draft-q4.log` 均显示在加载 `target.gguf` 后、ready 前收到 `0xC0000005`。去掉 Draft 后仍复现。CPU 同样报出 cache-limit 兼容提示并完成推理。具体故障模块待确认。
- 诊断分支 `diagnose/veri-1-opencl-startup` 已推送，代码提交 `09e65bf`。新增单次 OpenCL Target 启动探针及操作说明。复用发布包本地 EXE 和原有模型，采集 verbose stderr、进程退出状态、与后端匹配的 Windows Application Error 1000 字段。Mac PowerShell 7.7 用模拟进程覆盖 ready/非零退出/缺失模型，验证 XML 过滤和有符号退出码格式。真实 Windows PowerShell 5.1 与 OpenCL 尚待实机回传。
- 本地核对了发布包 EXE 和 ARM64 构建输出的 SHA-256 相同。EXE 含 COFF 符号，可在模块确认为 EXE 时用 PE ImageBase 加上事件中的模块偏移映射函数。

下一步：在骁龙本运行 probe_opencl_startup.ps1 并回传一个文本报告，获取故障模块与偏移后定位并修复 OpenCL 启动
