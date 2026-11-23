# 骁龙 attention 实机通过，第 0 层 post-RoPE 整图回放已准备发布

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-23 08:37:59 US/Pacific。

当前项目提交 `e935d5cbd5e431d97cb764fe3b24eda216873c33`。写入本轮检查点前的 Git 状态：

```text
## experiment/real-qnn-replay...origin/experiment/real-qnn-replay
 M Handoff.MD
 M PLAN.md
 M Tasks/INDEX.md
 M Tasks/TASK-20261121-voxt-snapdragon-asr.md
 M native/verify_attention_capture.h
 M native/verify_capture.h
 M scripts/win-arm64/current_handoff.ps1
 M tools/qnn-probe/prepare_ffn.py
 M tools/qnn-probe/projection.py
?? Tasks/HANDOFF-20261123-083303-voxt-snapdragon-asr.md
?? tools/qnn-probe/prepare_decoder_layer.py
```

- 骁龙 `e935d5c` attention 与完整 FFN 在同一轮通过，原图 CPU FP16 对照失败，内部 FP32 参考恢复。设备结论见 [上一检查点](HANDOFF-20261123-083303-voxt-snapdragon-asr.md)。
- 扩展原生采集记录第 0 层新 K/V、输入残差和层输出。按原生因果掩码及新 K/V 向量将八个候选与实际缓存位置对应，复用 256 列静态预算，区分 109 个历史位置与 8 个追加候选。
- 整张图连接缓存追加、FP16 Attention、按通道 A16/U8 attention 输出投影、FP16 残差和 RMSNorm、完整 A16/U8 SwiGLU FFN 及最后残差。独立参考与原生 dense Q8_0 重建分开评估。保留 CPU FP32 attention 复核，HTP 禁用 CPU fallback。
- Mac 的 flash/普通 attention 采集均通过。dense 重建相对原生层输出 L2 约 0.000123%，混合精度对 dense 约 0.934%。正常 ORT CPU 图相对独立混合精度参考 L2 为 0.0989% 和 0.1004%，FP32 attention 复核为 0.0594% 和 0.0614%。Mac 与 AArch64 PE 交叉构建成功。
- PowerShell 用真实 Mac 捕获和 ORT CPU 图模拟了整图通过及整图失败。通过时跳过两组已验收的子图，失败时两组自动继续并保留诊断。HTP 模拟不计实机。真实整图的 HTP 精度和耗时未验证。
- 整图以 post-RoPE 的 Q 和已生成的候选 K/V 为边界。QKV、QK-Norm 与 RoPE 的图内执行、接受候选后的跨轮 KV 提交与回滚以及完整 Target 仍待验证。

下一步：骁龙本运行一次固定入口 update_and_verify.ps1，回传 decoder-layer 段和失败时自动输出的子图诊断。
