# 骁龙 HTP 全链八个 top-1 一致，末层原生 down 超限

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-23 18:51:31 US/Pacific。

当前项目提交 `d94f2ecbbc89c5ce674aed4e813810680f349320`。写入本轮检查点前的 Git 状态：

```text
## experiment/real-qnn-replay...origin/experiment/real-qnn-replay
```

照片上半段 Windows 完整回放报告记录 672 个 QAIRT execute、28 层热态中位数合计 82.93 ms，native_hidden、CPU chain、HTP chain、HTP isolated 四组 top-1 均 8/8。HTP logits 相对 L2 1.960%，三个 DFlash aux L2 2.006%/1.621%/1.299%。总判定失败来自第 27 层原生 ffn_down 3.256% 超过 3%（累计 dense 6.938%）。照片下半段同一提交 d94f2ec 重跑，独立末层 QAIRT 24 个 execute、HTP/CPU L2 0.169%、HTP/Adreno L2 7.501%、独立 top-1 8/8。全链重跑 17/28 CPU、16/28 HTP；总预算剩 2.5 秒时启动第 16 层，初始化超时。因此不能据此认定该层有执行故障。后续针对末层原生投影。

下一步：用同一份末层原生 SwiGLU 输入单测 Q8_0 投影，多种精度路径对照，免去重复整链。
