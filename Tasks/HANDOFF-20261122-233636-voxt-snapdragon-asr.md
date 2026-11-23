# Adreno Q4 DFlash 单条实机通过，逐 token 一致，下一轮为 Voxt 31 条全量

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-22 23:36:36 US/Pacific。

当前项目提交 `773b8d8a2c866f497dd2a39a2b12014adf31c2ea`。写入本轮检查点前的 Git 状态：

```text
## veri/native-win-arm64...origin/veri/native-win-arm64
 M Handoff.MD
 M Tasks/TASK-20261121-voxt-snapdragon-asr.md
 M scripts/win-arm64/current_handoff.ps1
 M scripts/win-arm64/run_verify.ps1
```

- 2026-11-23 15:29:21 +08:00 的骁龙实机报告，提交 773b8d8a2c866f497dd2a39a2b12014adf31c2ea。OpenCL Target-only 和 Q4 DFlash 的 zh-plain-1 均 HTTP 200、15 个生成 token、正常退出，逐 token 与文本一致。Target 29/29 层和 Draft 6/6 层都显示 GPU offload。
- Target-only HTTP wall 4459 ms，Q4 DFlash 4012 ms，单条约少 10%。DFlash 14/14 候选通过，2 轮，avg_accept 7.00，avg_step 8.00。每轮 Draft 28.12 ms（12.6%）、Target Verification 189.55 ms（84.6%）、Context 6.29 ms（2.8%）。尚不能推广到 31 条。结果支持继续测 Verification 是否是全量瓶颈，之后再决定 NPU 切入顺序。
- 固定入口切到原有 Voxt Go 评测器，按四组 CPU/OpenCL x Target-only/Q4 DFlash 各 31 条运行。照片摘要显示误差、词典命中、累计主样本耗时、接收与分段计时，完整文件保存在运行目录 verification。使用现有权重及评测资产，评测器在 Windows 本机编译。Go 1.27.1+ 尚无实机已安装确认。
- Mac 用既有 31 条真实基准 JSONL 驱动全量四组脚本和报告，测试正常、无 profiling、OpenCL 子进程失败，并验证先前两条原生校验路径。Windows 的完整质量、接收和性能仍待实机。

下一步：骁龙本准备公司批准的 Go 1.27.1+，重跑固定入口并回传四组全量摘要
