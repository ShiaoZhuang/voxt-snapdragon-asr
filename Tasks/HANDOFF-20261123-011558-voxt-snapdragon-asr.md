# Windows CPU 与 OpenCL 四组 31 条均通过，Hexagon 八位置投影探针完成 CPU 对照

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-23 01:15:58 US/Pacific。

当前项目提交 `cd064ebb5c1886e6aa68dd95f01cce7e06a8fbd2`。写入本轮检查点前的 Git 状态：

```text
## experiment/hexagon-verify
 M PLAN.md
 M Tasks/TASK-20261121-voxt-snapdragon-asr.md
?? tools/qnn-probe/
```

- 2026-11-23 16:43:22 +08:00 骁龙实机报告，发布提交 cd064ebb5c1886e6aa68dd95f01cce7e06a8fbd2。首次 15:48 报缺 Go，最新报告本机后端、Go 评测器和四组 31 条全部 PASS，四组字典 7/10，两个设备 Target/DFlash 同设备逐 token 差异均为 0。
- CPU 纯 Target 与 Q4 Draft 综合错误率均 2.85%，主请求 wall sum 303.8/492.4 s。DFlash avg_accept 3.29、avg_step 4.29、47.0%、clean 6.00，zh-plain/en 0.00%，long 2.24%。Draft / Target / Context 488.76 / 556.90 / 105.96 ms/轮（42.4% / 48.4% / 9.2%）。
- OpenCL 纯 Target 与 Q4 Draft 综合错误率均 3.07%，wall sum 123.8/116.5 s。DFlash avg_accept 3.32、avg_step 4.32、47.5%、clean 6.00，zh-plain/en 0.00%，long 2.65%。Draft / Target / Context 31.39 / 210.11 / 6.90 ms/轮（12.6% / 84.6% / 2.8%）。这些是单次实机结果，按总主请求耗时比较，未包含编译或进程启动。
- 核对真实 Q8_0 GGUF：28 层、hidden 2048、FFN 6144、8 KV 头、头维 128、输出维 151936。F16 KV 112 KiB/位置，2,048/8,192 位置分别 224/896 MiB，八位置增量 896 KiB。当前 Target profiling 包住 llama_process + llama_synchronize，NPU 路径比较也需包含跨设备搬运及同步。
- 实验分支 experiment/hexagon-verify 新增 ORT/QNN synthetic QDQ 固定八位置投影。Mac ORT CPU 1.29.0 输出与独立整数参考最大 0 LSB，30 次运行；HTP 入口拒绝错误平台，锁定的 ONNX/ORT/QNN 依赖都有 Python 3.14 Windows ARM64 wheel。严格要求 HTP 禁用 CPU 回退并看到 QAIRT backend execute profiling。QNN HTP、完整模型块和真实 KV 回放均未实机验证。现有固定验收分支保留 31 条对照。

下一步：在公司批准的 Windows ARM64 Python 环境运行 QNN HTP 投影探针，并实现真实 Target KV 回放接口
