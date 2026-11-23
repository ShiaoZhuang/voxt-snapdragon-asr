# FFN 骁龙复测通过，attention CPU 对照诊断和 FP32 复核已准备

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-23 08:20:36 US/Pacific。

当前项目提交 `a071fe83bf427c08fa2c0176a0c10391cb341ae9`。写入本轮检查点前的 Git 状态：

```text
## experiment/real-qnn-replay...origin/experiment/real-qnn-replay
 M Handoff.MD
 M Tasks/INDEX.md
 M Tasks/TASK-20261121-voxt-snapdragon-asr.md
 M scripts/win-arm64/current_handoff.ps1
 M tools/qnn-probe/prepare_attention.py
 M tools/qnn-probe/projection.py
?? Tasks/HANDOFF-20261123-081734-voxt-snapdragon-asr.md
```

- `a071fe8` 的实机截图显示 FFN 通过、attention 采集通过，停在 Windows 的 CPU 对照。详见 [上一检查点](HANDOFF-20261123-081734-voxt-snapdragon-asr.md)。没有该次 CPU 的结构化数据，尚不能定因。
- CPU 非零退出时仍从预先保存的 JSON 输出 L2、最大误差占参考峰值和退出状态。Attention FP16 CPU 失败后使用相同 FP16 张量、内部 FP32 的正式 ONNX 对照图。CPU 和 HTP 各自的数值门槛延续 a071fe8。
- HTP 运行仍然使用原 FP16 attention 图。两条 CPU 路径都失败时，仍执行 HTP 并保存独立参考的数值及 QAIRT 事件，最终对照状态保持 FAIL。可信的 CPU 比较与独立参考同时通过才允许整体 PASS。
- Mac 对已捕获 flash 与普通 attention 样本均通过。FP16 CPU 对独立参考相对 L2 为 0.08963% 和 0.09186%，使用内部 FP32 后为 0.00196% 和 0.00341%。PowerShell 真实采集和 CPU 回放的模拟覆盖 CPU 原路径通过、FP32 恢复，以及两种 CPU 对照均失败仍保存 HTP 结果。HTP 模拟不计实机。Windows CPU 未通过的具体原因与真实 HTP 结果仍待验证。

下一步：骁龙本运行固定入口 update_and_verify.ps1，回传 attention 的 CPU 误差、FP32 复核结果及 QAIRT HTP 事件。
