# 5% 与 Top‑1 判据及 GGML Hexagon 同音频验收已接入固定入口，待骁龙实测

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-23 19:18:50 US/Pacific。

当前项目提交 `c54c37a26c4841c0e85c50a53e872c87dff1e2f6`。写入本轮检查点前的 Git 状态：

```text
## experiment/real-qnn-replay...origin/experiment/real-qnn-replay
 M Handoff.MD
 M Tasks/TASK-20261121-voxt-snapdragon-asr.md
 M native/main.cpp
 M scripts/win-arm64/build_native.ps1
 M scripts/win-arm64/current_handoff.ps1
 M scripts/win-arm64/probe_opencl_startup.ps1
 M tools/qnn-probe/prepare_decoder_layer.py
 M tools/qnn-probe/probe_ffn_down.py
 M tools/qnn-probe/replay_target.py
?? scripts/win-arm64/qnn_handoff.ps1
?? scripts/win-arm64/verify_ggml_hexagon.ps1
```

用户接受 5% 数值误差或八位置 Top‑1 一致；适用于末层原生 FFN down 重建。此前完整真机 QNN 回放的该项为 3.256%，HTP 最终 logits L2 1.960%，Top‑1 8/8，672 个执行事件。另一次总预算耗尽只完成 16/28 个 HTP 层，仍是未完成。扩展整链预算至 900 秒，保留 45 秒单 worker 超时和每层 QNN/CPU 对照。只有末层有限 down 偏差可由完整链的 token 结果接受，其他阶段、执行证据、非有限值和缺层继续检查。

固定入口连续运行 QNN 和 GGML 两条路线；前者失败仍尝试后者。GGML 后端从本机 SDK 构建独立产品目录，Target 指定 HTP0，音频与可选 Q4 draft 指定 Adreno。同音频对照 Adreno 与 GGML Hexagon 的 Target-only 和 DFlash；保存实际逐 token 序列、文本和请求时长。GGML 要求请求开始后的非零 DSP 算子周期，忽略初始化 profile。设备需要可用的 Hexagon SDK、驱动及匹配且受信任的算子库。固定入口不会安装驱动或改动系统信任。

Mac 原生构建及 Windows ARM64 交叉构建通过（这两次编译未链接 Hexagon SDK），本机无 HTP 的真实服务返回 invalid device: HTP0。Mac 用真实公开音频、Q8 模型及四组转录驱动验证了请求、计时与序列对照，DSP 事件为测试注入。覆盖成功、只有预热事件时失败，以及 QNN 失败仍执行 GGML。28 层真实输入和 ORT CPU 模拟 QNN 后端的 PowerShell 集成测试通过。判据注入覆盖 3.256%、7.5% 且 8/8、token 不一致、非有限值、其他阶段超限与缺执行。测试中曾发现可延后判定的布尔量无法用 JSON 序列化，已修复并复测。证据在 .local/ggml-hex-{host-build,windows-host-build,no-device,qnn-verification,gate-tests,route-tests-final}.log。PowerShell、Python 解析及 git diff --check 通过。

GGML Hexagon 设备构建、DSP 执行和实际速度均待机端；QNN 完整连续 ASR 尚未接入。

下一步：在骁龙本运行固定入口一次，核对两条路线的独立结论、四组请求 tok/s、完整 token 及请求内 DSP 事件。
