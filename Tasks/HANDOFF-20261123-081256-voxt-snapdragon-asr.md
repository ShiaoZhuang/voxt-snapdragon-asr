# 骁龙整层 FFN 子图已通过，真实 attention 和 FFN 合并实机回放已准备

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-23 08:12:56 US/Pacific。

当前项目提交 `5a1522a946c35811bf80ab2bf793ad7dceb70e80`。写入本轮检查点前的 Git 状态：

```text
## experiment/real-qnn-replay...origin/experiment/real-qnn-replay
 M Handoff.MD
 M PLAN.md
 M Tasks/INDEX.md
 M Tasks/TASK-20261121-voxt-snapdragon-asr.md
 M native/verify_capture.h
 M scripts/win-arm64/current_handoff.ps1
 M tools/qnn-probe/compare_capture.py
 M tools/qnn-probe/prepare_ffn.py
 M tools/qnn-probe/projection.py
?? Tasks/HANDOFF-20261123-080638-voxt-snapdragon-asr.md
?? native/verify_attention_capture.h
?? tools/qnn-probe/prepare_attention.py
```

- `5a1522a` 骁龙完整 FFN 实测结果见 [上一检查点](HANDOFF-20261123-080638-voxt-snapdragon-asr.md)。Adreno 捕获相对 dense Q8_0 的 L2 误差为 1.3317%，重编码误差约 1.0754%，HTP 相对同图 CPU 的 L2 为 0.0354%，热态中位数/P95 1.604/1.756 ms。
- 同一捕获现保存原生 attention 的 post-RoPE Q、真实历史与八个候选的缓存 K/V、原始掩码、可选物理 KV 行号和 attention 输出。读取支持原生 flash 和普通 attention 的不同布局。准备脚本检查掩码每个 query 仅增加一个可见位置，基于这份只读 KV 构造固定形状 FP16 ONNX Attention，禁用 HTP CPU fallback。
- Mac 同一公开样本分别验证 flash 和普通 attention。均捕获 256 个 KV 列，每个 query 可见 110–117 个位置，采集开启与关闭时转录和 token 一致。独立 FP64 复算与原生捕获的相对 L2 分别为 0.009407% 和 0.0000353%。ORT CPU 对独立 FP16 参考相对 L2 为 0.08963% 和 0.09186%。原完整 FFN CPU 对照仍为最大 1 步。
- Mac 原生和 Windows AArch64 PE 交叉构建通过。PowerShell 使用真实 Mac 采集和 CPU 图回放，模拟 HTP 两组通过及 FFN 失败仍继续 attention。当天证据位于被忽略的 `.local/attention-release.1tC2Wo` 和 `.local/real-qnn-release.l1_g5e85`。模拟 HTP 结果不计为设备实测。
- 单次固定入口合并两个子图，实际 attention HTP 的支持、数值和耗时仍待实机。当前 attention 只读已捕获 KV，KV 提交与回滚、图内 RoPE、完整 decoder 层与整轮验证仍是后续门槛。

下一步：骁龙本运行一次固定入口 update_and_verify.ps1，回传包含 full-ffn 和 attention 两段的 VOXT SNAPDRAGON REPORT。
