# 骁龙 Hexagon HTP 合成投影通过，扩大 A16 编码范围后最大误差 1 步

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-23 06:34:04 US/Pacific。

当前项目提交 `30433992593fd8a9e54bbe68b34c073098d8d83d`。写入本轮检查点前的 Git 状态：

```text
## veri/native-win-arm64...origin/veri/native-win-arm64
```

- 2026-11-23 22:16 Asia/Shanghai，骁龙固定入口在 `3043399` 报告总体 PASS。原生 ARM64 CPython 3.12.13 及依赖通过。
- CPU 参考 (49,152 个输出) 最大误差 0。默认 HTP 和关闭 LUT 的组均为 max/P95 32/30 步、45,160/49,152 输出超限、输出编码步距 32、6 个 QAIRT execute 事件、退出 1。
- 扩大 A16 编码的 HTP 组为 max/P95 1/1 步、0/49,152 输出超限、输出编码步距 1、216 个 QAIRT execute 事件、退出 0。30 次热态主机往返中位数/P95 为 0.907/1.468 ms。
- 只改变 A16 编码与对应 scale 即可通过这个固定形状。关闭 LUT 本身未改变误差。结果来自单个合成投影，真实权重、KV、logits 及端到端加速仍未验证。

下一步：在 Mac 上捕获真实 Voxt DFlash 八位置验证的第一层 FFN 输入与投影输出，准备实机回放。
