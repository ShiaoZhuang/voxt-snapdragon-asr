# 28 层 HTP 实机串联完成，末层 FFN down 定点对照已就绪

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-23 18:59:06 US/Pacific。

当前项目提交 `d94f2ecbbc89c5ce674aed4e813810680f349320`。写入本轮检查点前的 Git 状态：

```text
## experiment/real-qnn-replay...origin/experiment/real-qnn-replay
 M Handoff.MD
 M Tasks/INDEX.md
 M Tasks/TASK-20261121-voxt-snapdragon-asr.md
 M native/main.cpp
 M scripts/win-arm64/current_handoff.ps1
?? Tasks/HANDOFF-20261123-185131-voxt-snapdragon-asr.md
?? native/verify_ffn_down.h
?? tools/qnn-probe/probe_ffn_down.py
```

### 实机结论
- 用户照片上半段记录 672 个 QAIRT execute、28 层热态中位数合计 82.93 ms。原生隐藏状态、CPU 链、HTP 链及 HTP 独立末层各自 top-1 都达到 8/8；HTP logits 相对 L2 1.960%。本轮完整回放报告仍判 FAIL，唯一原生超限为第 27 层 ffn_down 3.256%，累计 dense L2 6.938%，下一大项为 V 0.661%。
- 照片下半段 `d94f2ec` 重跑的独立末层 HTP/CPU L2 0.169%、HTP/Adreno 7.501%，QAIRT 24 次、top-1 8/8。第 16 层开始时总预算只剩 2.5 秒，在初始化阶段超时；完成记录为 HTP 16/28、CPU 17/28。这是该次剩余预算，尚不能推断第 16 层有故障。

### 本轮处置
- 固定入口默认只执行第 27 层的 down 投影。优先复用现有公开样本捕获，缺少完整数据时自动采集一次。相同的 8×6144 SwiGLU 和真实 Q8_0 权重分别执行 Adreno 八行、四行、逐行、解量化权重 FP32 路径及 HTP A16/U8 投影。对照主机 FP32 参考、原生捕获输出、替换后的 logits 与八位置 top-1。独立执行各变体且禁用 CPU fallback，原参考 3% 判定沿用原分母，显式保留超限。内部保留 `-FullReplay`，默认不再重跑已得到结果的整链。
- Mac 与 Windows ARM64 源码构建通过（`.local/voxt-down-probe-build.log`、`.local/windows-down-probe-build.log`）。同一真实本地捕获上，GGML CPU 的 Q8 三种分批均为 0.637% L2、FP32 约 0.0001%；Apple Metal 的四种结果约 0.0001%；全部 top-1 一致 8/8。真实 Mac 原生程序配合模拟 HTP 的 PowerShell 验证通过新采集、复用及原始参考超限仍保留报告的路径（`.local/down-probe-handoff-test.log`）。`git diff --check`、PowerShell 和 Python 解析通过。
- 骁龙各独立投影仍待实测。全链耗时、上线替换、原生 KV 跨轮提交与连续推理仍未验收。

下一步：骁龙固定入口运行末层投影对照一次，取得 Q8 八行、四行、逐行、FP32 与 HTP 对同一输入的结果。
