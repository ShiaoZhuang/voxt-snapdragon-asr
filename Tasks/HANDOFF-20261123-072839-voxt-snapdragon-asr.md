# 骁龙合成投影复测通过，固定入口已切换到真实 DFlash 投影回放

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-23 07:28:39 US/Pacific。

当前项目提交 `7ec8e958f2fe58b17c710e542062a8abbadf5efe`。写入本轮检查点前的 Git 状态：

```text
## experiment/real-qnn-replay...origin/experiment/real-qnn-replay
 M Handoff.MD
 M PLAN.md
 M scripts/win-arm64/current_handoff.ps1
 M scripts/win-arm64/probe_opencl_startup.ps1
 M tools/qnn-probe/compare_capture.py
 M tools/qnn-probe/projection.py
 M tools/qnn-probe/requirements-win-arm64.txt
?? tools/qnn-probe/prepare_replay.py
```

- 新截图中，骁龙本在 `23ae586` 复跑合成探针，总体 PASS。wide-A16 最大/P95 误差 1/1 步、0/49,152 输出超限、216 个 QAIRT execute 事件、退出 0，30 次主机往返中位数/P95 为 0.928/1.241 ms。默认和 LUT-off 最大误差仍为 32 步。首次 `3043399` 的中位数/P95 为 0.907/1.468 ms。
- 真实回放工作流校验现有 target、draft、音频投影和单条公开 WAV 的 SHA-256，使用已有 Windows 工具链只构建后端，以 Adreno DFlash 捕获第 0 层 FFN 输入、输出与位置，并用 SSE 核对首个完整八位置批次的 token。独立准备进程使用 gguf 读取本地 Q8_0 权重，按输出通道重编码权重，在同一 QDQ 图中分别运行 CPU 与 HTP。
- Mac 的真实采集和 ORT CPU 回放通过。重编码相对原 Q8_0 的 L2 误差为 0.7762%，49,152 个 CPU 输出相对独立整数参考最大偏差 1 步、0 个超限。模拟固定入口使用真实 Mac 转录和 CPU 图，能正确判定 HTP 对照的通过和超差失败。旧 OpenCL 快测模拟与 PowerShell 语法检查通过。
- ARM64 Windows 后端 Mac 交叉编译通过，生成 AArch64 PE。Windows CPython 3.12 ARM64 的 wheel 解析通过，新增 gguf 读取器从本机配置的源安装。模拟的 HTP 指标不作为设备实测数据。
- 本轮实机门槛为真实批次采集、一层投影在 HTP 的执行事件、最大误差 2 步及正常退出。模型、日志与捕获数据留在本地，无需重跑完整评测。真实权重在 HTP 的支持、误差和速度仍待骁龙本验证。

下一步：骁龙本运行固定入口 update_and_verify.ps1，回传整段 VOXT SNAPDRAGON REPORT，核对采集、重新编码误差和真实投影的 QAIRT 证据。
