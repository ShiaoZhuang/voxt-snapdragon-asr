# 骁龙合成 HTP 已通过，Mac 已捕获真实 DFlash 八位置并验证 Q8_0 投影参考

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-23 06:40:20 US/Pacific。

当前项目提交 `23ae5868386b3d17a994b602beed8f234a8fe996`。写入本轮检查点前的 Git 状态：

```text
## experiment/real-qnn-replay
 M PLAN.md
 M patches/llama-voxt.patch
?? native/verify_capture.h
?? tools/qnn-probe/compare_capture.py
```

- Windows 合成探针通过的证据见 [上一检查点](HANDOFF-20261123-063404-voxt-snapdragon-asr.md)。已将结果提交到实机交接分支，现有固定脚本仍复现实机已通过的合成探针。
- 实验分支 `experiment/real-qnn-replay` 增加 opt-in 的 `VOXT_VERIFY_CAPTURE_DIR`。只有单槽 Voxt Final 的完整 DFlash 验证批次能触发一次采集，写出第 0 层 FFN norm、up projection 和 token/位置清单。
- Mac 原生后端 build `build/voxt-3884ace2c8f2` 构建通过。用发布模型和公开 `zh-plain-1.wav` 两次验证，实际位置 109–116，矩阵形状为 8×2048 和 8×6144，批中 anchor 和 7 个候选与 SSE 验证 trace 逐项相同。开启或关闭捕获的完整转录与 token 一致，14/14 个 draft 接收一致。证据保存在忽略目录 `.local/real-verify-capture.4x5qd0tx`，捕获数据与模型不在 Git。
- 用 `tools/qnn-probe/compare_capture.py` 从 GGUF 解码 `blk.0.ffn_up.weight` 重算捕获结果，相对 L2 为 `7.51398e-7`，最大绝对误差 `2.86102e-6`。此单批次的 A16/U8 CPU 模拟中，整矩阵 scale 与按输出通道 scale 的相对 L2 分别为 2.590% 与 0.776%。
- 真实投影仍未在骁龙 HTP 上运行。下一轮交接需同时报告量化重编码引入的误差和 QNN 相对已编码 CPU 图的额外误差。端到端质量与速度继续使用后续完整验证回放与冻结的 Adreno 基线。

下一步：把逐输出通道 A16/U8 真实权重投影接入 QNN 回放，对相同输入核对 CPU 参考、HTP 事件和误差，再更新固定骁龙入口。
