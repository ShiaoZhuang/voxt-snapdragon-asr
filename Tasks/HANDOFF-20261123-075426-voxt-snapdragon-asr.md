# 真实 up 投影实机通过，完整八位置 FFN 回放已准备发布

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-23 07:54:26 US/Pacific。

当前项目提交 `162597b43077e632695abbd8144b4c4c480ddbea`。写入本轮检查点前的 Git 状态：

```text
## experiment/real-qnn-replay...origin/experiment/real-qnn-replay
 M Handoff.MD
 M PLAN.md
 M Tasks/INDEX.md
 M Tasks/TASK-20261121-voxt-snapdragon-asr.md
 M native/verify_capture.h
 M scripts/win-arm64/current_handoff.ps1
 M tools/qnn-probe/compare_capture.py
 M tools/qnn-probe/projection.py
?? Tasks/HANDOFF-20261123-074953-voxt-snapdragon-asr.md
?? tools/qnn-probe/prepare_ffn.py
```

- 骁龙 `162597b` 的真实 up 投影通过，具体数值见 [上一检查点](HANDOFF-20261123-074953-voxt-snapdragon-asr.md)。本轮将同一公开样本的真实八位置回放扩展到第 0 层以 norm 输出为入口、down 输出为末端的完整 FFN。
- 捕获增加 `ffn_out.f32`，仍只在首个完整验证批次写盘。验证 token、转录 token、14/14 接收及公开模型文件均用原有对照。FFN ONNX 矩阵使用逐输出通道 U8 权重与 U16 激活。Sigmoid 的输出采用 QNN 2.8.0 的 U16 约定 `scale = 1/65536, zp = 0`，Mul 和投影均有显式 QDQ 边界。
- Mac Metal 样本位置 109–116，dense Q8_0 的 FFN 输出与原始捕获相对 L2 误差为 0.0001614%。A16/U8 重编码后的独立参考与 dense Q8_0 相对 L2 误差为 1.0754%。同一张 QDQ 图的 16,384 个 ORT CPU 输出至多偏离独立参考 1 个量化步长，0 个超限。原合成探针 CPU 对照仍为零误差。
- Windows ARM64 交叉编译成功，产物为 AArch64 PE。Mac 驱动固定入口的模拟实测通过，使用真实 Mac 转录与 CPU 回放，模拟 HTP 通过及拒绝超差。实际 HTP 完整子图的执行和时延仍待 Windows 实机。
- CPU 与独立参考的门限保留 2 步。针对完整 FFN 多次舍入及 sigmoid 近似，实机 HTP 与 CPU 及独立参考均需满足相对 L2 ≤0.1%、最大误差 ≤参考输出峰值的 0.5%，并且证明 QAIRT 后端执行、正常退出。超过 2 步的输出数仍记录。该门限用于当前单个子图诊断，完整 Target 的 logits、KV 与端到端转录有单独门槛。

下一步：骁龙本运行固定入口 update_and_verify.ps1，回传整段 VOXT SNAPDRAGON REPORT，验证完整 FFN 的 QAIRT 事件、误差与耗时。
