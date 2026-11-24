# Voxt 骁龙 Windows ARM64 本地 ASR
status: in-progress

current_handoff: [HANDOFF-20261123-235911-voxt-snapdragon-asr.md](HANDOFF-20261123-235911-voxt-snapdragon-asr.md)

## 目标与边界
保留 Voxt 交互和协议，从干净上游构建 Qwen3-ASR 1.7B + DFlash。旧骁龙原型只提供性能现象参考。
## 仓库与依据
当前独立项目根目录，分支 main。相邻 sglang-omni 仓库的 feat/dflash-profile-benchmark 分支为 Mac 基准。实施与验收以 [PLAN.md](../PLAN.md) 为准。
## 实施与验收清单
- [x] 确认路线、实机交接约定与验收阈值，初始化任务跟踪。
- [x] 固定源码、模型 SHA 与评测清单，重测 Mac 基准。
- [x] 导出 F16 音频塔和因果 Draft GGUF，完成 Apple CPU 与 Metal 同样本推理对照。
- [x] 实现 Voxt 离线 Final 托管协议、Target-only 与固定 DFlash，Mac Metal 31 条逐 token 等价通过。
- [x] 交付 Veri 1 本地离线包，确认原生 Windows ARM64 EXE/DLL 与模型、评测集哈希。
- [x] Oryon CPU 两种模式通过单条实机快测，Q4 DFlash 与 Target-only 逐 token 一致。
- [x] 骁龙本固定入口完成 Git 同步、验证任务调用和屏幕报告输出。
- [x] 修复 Adreno OpenCL Target 启动，骁龙本完成纯 Target 单条转录。
- [x] 验证 Adreno OpenCL 的 Q4 DFlash 单条接收和 Target-only 逐 token 一致性。
- [x] 获取 Oryon/Adreno 四组 31 条实机结果，满足质量与接收门槛。
- [ ] 移植自适应投机回退，并基于骁龙结果测延迟。
- [x] 完成固定八位置 QNN 投影探针的 CPU 数值对照。
- [x] 骁龙实机安装并选用 ARM64 Python，完成 QNN 依赖预检。
- [x] 骁龙实机确认合成 QNN 投影在 HTP 执行、数值达标并记录 profiling。
- [x] 捕获真实 DFlash 八位置验证的第一层 FFN 投影并建立 Q8_0 数值参考。
- [x] 实现真实投影回放与实机交接，完成 Mac 上的 QDQ 图、整数参考和固定入口验证。
- [x] 在骁龙 HTP 回放真实激活和真实权重重编码的第一层 FFN up 投影。
- [x] 捕获完整 FFN 输出，生成 up、gate、SwiGLU、down QDQ 图并完成 Mac 独立参考校验。
- [x] 同一层 FFN 的完整子图在骁龙 HTP 上回放并实测误差与性能。
- [x] 完成第 0 层 post-RoPE attention 的真实 KV 和原生掩码采集、独立参考和 Mac ORT 对照。
- [x] 骁龙 HTP 实测第 0 层 post-RoPE attention 和真实历史 KV 的误差、执行与耗时。
- [x] 将 KV 追加、post-RoPE attention、残差、归一化和完整 FFN 编入同一图并完成 Mac 数值对照。
- [x] 骁龙实测第 0 层 post-RoPE 整图的 HTP 精度、执行与耗时。
- [x] 合并完整第 0 层、post-RoPE 对照与四项 KV 可见性检查，验证固定入口和自动故障诊断。
- [x] 一次实机交接验收两张图和 KV 可见性。
- [x] 捕获完整 Target 的真实校验状态，完成 28 层串联 CPU 对照和词表输出验证。
- [x] 骁龙前 27 层 HTP 串联通过，末层原生重建超限。
- [x] 末层原生逐阶段检查与独立 HTP 回放并入固定入口，验证超限时仍可采集 logits。
- [x] 末层优先单测，按层隔离 QNN 进程并保留超时前的数据和阶段。
- [x] 骁龙实测已完成 28 层 HTP 串联、DFlash 辅助张量和八位置 top-1。
- [x] 明确末层 FFN down 偏差的验收标准并验证 5% 与完整链 top-1 判定。
- [x] 用相同输入在骁龙实测 Q8 批 8、批 4、逐行、FP32 和 QNN HTP 的末层投影与 Top‑1。
- [x] 骁龙 28 层 QNN Target replay 按新门槛通过，记录 81.59 ms 与设备执行证据。
- [x] 固定入口补装缺失的 Windows ARM64 Hexagon SDK，验证缓存与失败后的 Adreno 基线。
- [x] 骁龙实测 Adreno Target-only 3.76 tok/s 与 Q4 DFlash 4.12 tok/s。
- [x] 将满八位置验证接入连续转录，用真实音频在本地验证两轮 KV、aux 和 token。
- [x] 启动器实时显示两条路线状态，SDK 吊销检查失败即时退出下载并保留已完成报告。
- [ ] 骁龙本实测 GPU + QNN HTP 与全 GPU DFlash 的请求吞吐及设备执行证据。
- [ ] 骁龙本地实测 GGML Hexagon Target 的执行、转录 token 和请求 tok/s。
- [ ] 完成 Hexagon Target 验证前向的实机可行性与性能报告。
- [ ] 验收 Windows 桌面听写与实时接口。
## Current State
骁龙仍在调用旧启动器，已核对远端支持 Route。
## 依赖与下一步
骁龙结果依赖离线实机交接。下一步：骁龙从已发布分支刷新本地启动器，再按 GgmlHexagon 路线运行并回传报告。
