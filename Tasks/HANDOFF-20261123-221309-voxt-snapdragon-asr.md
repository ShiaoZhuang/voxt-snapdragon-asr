# 八位置 HTP 验证已接入实际转录与一键 TPS 对比，待骁龙真机测量

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-23 22:13:09 US/Pacific。

当前项目提交 `d44764ad9b3b4af9a2d66c5ca8390163828f5d88`。写入本轮检查点前的 Git 状态：

```text
## experiment/real-qnn-replay...origin/experiment/real-qnn-replay
 M Handoff.MD
 M native/transcriptions.inc
 M patches/llama-voxt.patch
 M scripts/win-arm64/current_handoff.ps1
 M scripts/win-arm64/probe_opencl_startup.ps1
 M tools/qnn-probe/prepare_decoder_layer.py
?? native/live_verify.h
?? scripts/win-arm64/verify_live_qnn.ps1
?? tools/qnn-probe/live_verify.py
```

本轮把 QNN verifier 放在现有单槽 DFlash 解码的满八位置分支。常规 prefill、Draft 和非满批继续使用 Adreno；满批的 28 层由一个禁用 CPU fallback 的持久 QNN HTP 会话执行，主机完成 embedding 和词表输出层。按活动掩码读取实时历史 KV，按本轮位置生成 RoPE，回填每层八位置 FP16 KV、三处 aux 和真实 logits，保持现有 llama.cpp 接受、拒绝和回滚流程。每轮本地 IPC、KV 搬运和词表耗时计入完整请求；首轮校准及会话初始化在计时外。首版固定短上下文容量为校准图支持的 248 历史位置，性能结果不能外推到长音频。样本优先验证满批替换，实机 QNN 汇编、跨轮精度和请求吞吐仍待确认。

固定入口先跑全 GPU 与 QNN live 的 zh-plain-1.wav，使用各自正常的数据路径；只在文本、逐 token、服务及 worker 满批计数与 QAIRT 都满足时打印两者倍率。若 QNN 受阻，GGML Hexagon 仍单独沿原来的 SDK 安装与转录测试获得状态。默认仍不跑完整离线回放和 CPU 基准。

本地以真实捕获标定量化图，Mac 原生服务和 ORT CPU 测试 worker 跑通同一音频的完整 2/2 轮及 EOS，15 个生成 token 相同，DSP 计数为零。两轮草稿均成功接收，未覆盖真实拒绝分支。证据 .local/live-qnn-final/transcription.log 和 worker_report.json。Mac 与 Windows ARM64 交叉构建完成，证据 .local/live-verify-final-build.log 和 .local/live-verify-final-windows-build.log。PowerShell 模拟报告验证有设备证据才打印倍率、缺设备证据仍继续 GGML，见 .local/live-qnn-handoff.log。PowerShell/Python 解析、上游补丁检查和 git diff --check 通过。QNN 物理 HTP 尚未跑这份整合图，本地耗时属于 CPU 测试。

下一步：在骁龙本运行原固定入口，从 QNN live 区段确认匹配的完整 token、HTP 轮数、QAIRT 执行和请求 tok/s，GGML Hexagon 照常单独回报。
