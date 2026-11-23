# 第 0 层 HTP 实机验收通过，28 层串联回放已就绪

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-23 09:09:06 US/Pacific。

当前项目提交 `636c260c855f7e630aa751012bef618bb089077d`。写入本轮检查点前的 Git 状态：

```text
## experiment/real-qnn-replay...origin/experiment/real-qnn-replay
 M Handoff.MD
 M Tasks/INDEX.md
 M Tasks/TASK-20261121-voxt-snapdragon-asr.md
 M native/verify_attention_capture.h
 M native/verify_capture.h
 M scripts/win-arm64/current_handoff.ps1
 M scripts/win-arm64/probe_opencl_startup.ps1
 M tools/qnn-probe/prepare_decoder_layer.py
 M tools/qnn-probe/prepare_ffn.py
 M tools/qnn-probe/projection.py
?? Tasks/HANDOFF-20261123-090103-voxt-snapdragon-asr.md
?? tools/qnn-probe/replay_target.py
```

### 实机证据
- Windows 验证提交 `636c260c855f7e630aa751012bef618bb089077d`。用户截图 2026-11-24 00:51:25 +08:00，`full-decoder`、`decoder-layer` 和各自历史屏蔽、接受 0/1/3 候选共四项 KV 可见性均 PASS。完整层 QAIRT 240 个后端执行事件，HTP 对 CPU L2 0.1430%，30 次热态中位数/P95 3.049/3.458 ms。post-RoPE 对照 2.794/4.508 ms。

### 交付与验证
- 固定入口直接拉取本批任务。原生 Adreno 对公开 zh-plain-1 音频采集一轮真实 DFlash 八位置（109–116）中 28 层隐藏输入、输出、历史 K/V 及 151936 列 logits。复用每层静态完整图，将 HTP 产生的隐藏输出输入下一层。逐层检查同输入 CPU 参考及 QAIRT 后端执行。主机使用原 Q8_0 词表投影对照全部 logits。另记录 Draft 配置所列第 2、14、25 层的辅助输入误差。
- Mac 原生和 Windows ARM64 交叉构建成功（`.local/voxt-target-build.log`、`.local/windows-target-build.log`）。真实 Mac 采集在默认和关闭 flash attention 时均完成（`.local/voxt-target-capture.log`、`.local/voxt-target-plain-capture.log`）。采集开关的真实转录逐 token 一致。
- Mac CPU 28 层连续回放全部通过，最差单层对独立参考 L2 0.1111%。连续链最终 logits 对 native 相对 L2 1.332%，八个位置 top-1 全匹配。原生隐藏状态经主机 LM head 后相对 L2 0.000076%，top-1 8/8。三处 CPU 辅助张量对 native 的 L2 1.252%、1.214%、0.951%。结果位于 `.local/target-reference-latest` 指向的 result 目录。
- PowerShell 真实捕获与数值回放配合模拟 HTP 通过正常流程。注入第 14 层初始化错误后，剩余层继续诊断，自动跑第 0 层对照，总体保留失败，未将断开的链标为通过。测试见 `.local/target-handoff-test.log`。固定入口脚本原文件无改动，`git diff --check` 和 Python 语法检查通过。
- 本批使用每层原生历史缓存、独立设备会话和主机词表投影。Windows 全链首次执行、原生 KV 跨轮提交和连续转录仍待验证。各层计时之和仅用于定位，不作为连续转录延迟。

下一步：骁龙本运行一次固定入口，回传 28 层、QAIRT、DFlash 辅助输入和八位置 top-1 的终端摘要。
