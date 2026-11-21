# Veri 1 等待骁龙实测，已补记 Mac MLX 与 llama.cpp 的 Q4 对照

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-21 08:57:46 US/Pacific。

当前项目提交 `b4e4e56dc89e3e50f61fb194db3b26905f50c725`。写入本轮检查点前的 Git 状态：

```text
## main
```

- 重算现有 MacBook M3 Pro 原始记录 .local/mac-baseline-full/draft-q4.jsonl、.local/mac-baseline-full/draft-q8.jsonl 与 .local/native-matrix/draft-q4.jsonl。相同 31 条 main zh，共 368.383 秒音频。排除预热和去偏置附加请求，无新推理作业。
- MLX Q4：输出 951 token，端到端 11.748 s，分段 Draft/Target/Context 0.740/3.884/0.117 s，222 轮，17.495 ms/轮 Target。用输出 token 除以这三段总时长约 200.6 TPS。llama.cpp Q4：输出 948 token，端到端 16.361 s，分段 1.968/4.039/0.133 s，221 轮，18.275 ms/轮 Target，同口径约 154.4 TPS。llama.cpp 单独的 eval time 约 157.1 TPS（日志计数含结束 token，与三段口径不同）。三段 TPS 是 profiling 近似，不包含全部解码杂项，也未重新做交错 A/B。
- Voxt 1.7B 在启用 Draft 时默认传 8 位，MLX Q4 使用 VOXTNEW_DRAFT_BITS=4 覆盖。基准固定策略。MLX Q4 和 Q8 转录正文 31/31 一致，avg_accept 3.428/3.448。草稿阶段 0.740/0.970 s，总耗时 11.748/11.975 s。
- 上游参考仓库 HEAD 为 6efb1212b6e1196ed1140040d9e4e3069f6cb0a8，Capture.swift 有既有未提交改动。

下一步：回收 Veri 1 的 Oryon CPU 与 Adreno GPU 实测报告
