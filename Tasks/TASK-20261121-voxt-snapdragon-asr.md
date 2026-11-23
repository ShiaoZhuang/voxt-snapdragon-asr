# Voxt 骁龙 Windows ARM64 本地 ASR
status: in-progress

current_handoff: [HANDOFF-20261123-083759-voxt-snapdragon-asr.md](HANDOFF-20261123-083759-voxt-snapdragon-asr.md)

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
- [ ] 骁龙实测第 0 层 post-RoPE 整图的 HTP 精度、执行与耗时。
- [ ] 完成 Hexagon Target 验证前向的实机可行性与性能报告。
- [ ] 验收 Windows 桌面听写与实时接口。
## Current State
骁龙 attention 实机通过，第 0 层 post-RoPE 整图回放已准备发布。
## 依赖与下一步
骁龙结果依赖离线实机交接。下一步：骁龙本运行一次固定入口 update_and_verify.ps1，回传 decoder-layer 段和失败时自动输出的子图诊断。
