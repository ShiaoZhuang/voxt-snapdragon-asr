# post-RoPE 整图实机通过，多步验证已就绪

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-23 08:49:39 US/Pacific。

当前项目提交 `f14b7d0d920cc7e5f63db1bced6fc94e02c2da97`。写入本轮检查点前的 Git 状态：

```text
## experiment/real-qnn-replay...origin/experiment/real-qnn-replay
 M Handoff.MD
 M Tasks/INDEX.md
 M Tasks/TASK-20261121-voxt-snapdragon-asr.md
 M native/verify_attention_capture.h
 M scripts/win-arm64/current_handoff.ps1
 M tools/qnn-probe/prepare_decoder_layer.py
 M tools/qnn-probe/projection.py
?? Tasks/HANDOFF-20261123-084327-voxt-snapdragon-asr.md
```

### 实机基线
- `f14b7d0`，真实 DFlash 八位置、109 历史位置、256 列。post-RoPE 整图 QAIRT 216 个执行事件。HTP 对独立参考 L2 0.1307%，对采用 FP32 attention 的 CPU 参考 L2 0.1309%，热态往返中位数/P95 2.322/2.881 ms（30 次）。

### 本轮交付
- 固定入口保持原路径，更新 `veri/native-win-arm64` 的源码工作树。一次本机构建和一次 Adreno 捕获后，运行 full-decoder 与 post-RoPE 两张 HTP 图。完整图执行输入 RMSNorm、Q/K/V、Q/K norm 和 M-RoPE 旋转，继而执行 KV 追加、attention、输出投影、残差和 FFN。主机根据捕获的真实位置与运行参数计算 RoPE 系数。
- 两张图均检查屏蔽的历史 padding 和接受 0、1、3 个候选时的前缀可见性；各自复用原推理会话。post-RoPE 对照失败时继续 FFN、attention 子图诊断。CPU 仅运行小图对照。
- 本地 Mac 原生和 Windows ARM64 交叉构建均 exit 0，交叉产物留在本机。实际公开语音捕获测试通过，开关采集逐 token 一致（`.local/voxt-full-decoder-capture.log` 与 `.local/voxt-full-decoder-plain-capture.log`）。
- 完整图 Mac ORT CPU 对独立参考相对 L2 0.0696%，普通 attention 路径 0.0703%；post-RoPE 对照 0.0594%。两张图的四项可见性检查通过。完整图密集 Q/K/V 与采集的 L2 分别 0.021% / 0.022% / 0.021%。完整图混合精度对采集最终层输出 L2 1.143%（`.local/real-qnn-release.0dj5z0fo/user checkout/pass`）。
- `.local/batch-decoder-handoff-test.log` 中用真实采集、真实 Mac CPU 和模拟 HTP 验证正常、完整图失败后继续、post-RoPE 失败后回跑子图三条路径。独立固定入口夹具在连续三个提交上通过（`.local/batch-decoder-launcher-test.log`）。`git diff --check` 通过。
- Windows HTP 对完整图和 KV 可见性的执行仍待实机回传。测试针对真实采集的第 0 层静态图，原生 KV 跨轮提交与整体 NPU 推理仍待验收。

下一步：骁龙本用固定入口运行一次，回传 VOXT SNAPDRAGON REPORT，验收完整第 0 层 HTP、post-RoPE 对照及 KV 可见性。
