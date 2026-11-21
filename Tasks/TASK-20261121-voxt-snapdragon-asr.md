# Voxt 骁龙 Windows ARM64 本地 ASR
status: planning

current_handoff: [HANDOFF-20261121-025026-voxt-snapdragon-asr.md](HANDOFF-20261121-025026-voxt-snapdragon-asr.md)

## 目标与边界
保留 Voxt 交互和协议，从干净上游构建 Qwen3-ASR 1.7B + DFlash。旧骁龙原型只提供性能现象参考。
## 仓库与依据
当前项目根目录，待初始化 Git。相邻 sglang-omni 仓库的 feat/dflash-profile-benchmark 分支为 Mac 基准。实施与验收以 [PLAN.md](../PLAN.md) 为准。
## 实施与验收清单
- [x] 确认路线、实机交接约定与验收阈值，初始化任务跟踪。
- [ ] 固定源码、模型 SHA 与评测清单，重测 Mac 基准。
- [ ] 实现 Voxt 协议、Target-only 与 DFlash，验证同设备逐 token 等价。
- [ ] 交付 Veri 包，获取 Oryon/Adreno 四组 31 条结果，满足计划中的质量与接收门槛。
- [ ] 完成 Hexagon Target 验证前向的实机可行性与性能报告。
- [ ] 验收 Windows 桌面听写与实时接口。
## Current State
计划已确认。当前工作区已有计划与任务文档，工程实现和实机验证待开始。
## 依赖与下一步
Mac 侧可开始冻结基准。骁龙结果依赖通过打包和离线交接在实机执行。下一步在独立项目根目录初始化 Git，登记基准来源。
