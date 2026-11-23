# Voxt 骁龙 Windows ARM64 本地 ASR
status: in-progress

current_handoff: [HANDOFF-20261123-022859-voxt-snapdragon-asr.md](HANDOFF-20261123-022859-voxt-snapdragon-asr.md)

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
- [ ] 骁龙实机确认 QNN 投影在 HTP 执行并记录 profiling。
- [ ] 完成 Hexagon Target 验证前向的实机可行性与性能报告。
- [ ] 验收 Windows 桌面听写与实时接口。
## Current State
骁龙 HTP 探针停在 Python 预检，固定入口已加入 ARM64 解释器发现与诊断。
## 依赖与下一步
骁龙结果依赖离线实机交接。下一步：骁龙本在仓库根目录运行 .\scripts\win-arm64\update_and_verify.ps1，拍回 VOXT SNAPDRAGON REPORT，确认是否选到 ARM64 解释器及是否出现 QAIRT backend execute 事件。
