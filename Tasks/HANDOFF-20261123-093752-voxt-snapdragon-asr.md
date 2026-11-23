# 骁龙前 27 层 HTP 通过，末层逐阶段回放已就绪

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-23 09:37:52 US/Pacific。

当前项目提交 `bc6f9c01ca3a646f62c1d8a71324338cb0e4f2ee`。写入本轮检查点前的 Git 状态：

```text
## experiment/real-qnn-replay...origin/experiment/real-qnn-replay
 M Handoff.MD
 M Tasks/INDEX.md
 M Tasks/TASK-20261121-voxt-snapdragon-asr.md
 M native/verify_capture.h
 M scripts/win-arm64/current_handoff.ps1
 M tools/qnn-probe/prepare_decoder_layer.py
 M tools/qnn-probe/replay_target.py
?? Tasks/HANDOFF-20261123-092951-voxt-snapdragon-asr.md
```

### Windows 实机证据
- 截图提交 `bc6f9c01ca3a646f62c1d8a71324338cb0e4f2ee`，Windows 在 2026-11-24 01:14:28 +08:00 报告 28 层原生捕获与转录 PASS。前 27 层 HTP 与 CPU 通过，QAIRT 648 次执行，各层热态中位数合计 109.53 ms。零基第 27 层进入设备前触发旧的 dense 累计重建 3% L2 门槛，原报告没有末层 HTP、logits 或具体误差。第 0 层两条回放与 KV 可见性补测通过。

### 修复与本地验证
- 拆分末层原生参考检查与 HTP 执行。完整采集时沿用 3% 相对 L2 门槛，以每阶段实际输入校验 Q/K/V、attention、输出投影、FFN RMSNorm、up/gate、SwiGLU、down，另报告整层累计误差并校验末层残差闭合。没有中间数据时使用原整层重建判断。在开发验证中确认 ggml 会复用投影缓冲区，改为用相加前后的实测状态恢复投影贡献。
- 原生重建超限时保留失败状态，继续执行连接图、以原生输入单独执行末层以及计算两者八位置 top-1。链中断时保留第 0 层自动诊断。HTP 与同输入 CPU 精度门槛保持不变。固定入口未改动。
- Mac 真模型 28 层与八位置 top-1 通过，末层原生累计 L2 0.01335%，最大单阶段 L2 0.05472%。Mac/Windows ARM64 构建、真实音频采集、固定脚本正常流程、模拟 HTP 和失败分支均完成（`.local/voxt-final-layer-build.log`、`.local/windows-final-layer-build.log`、`.local/final-layer-reference.log`、`.local/final-layer-handoff-test.log`）。注入单阶段 down 误差后，在 28/28 执行结果及 logits 都齐备的情况下仍判 FAIL。注入多次小误差的本地测试显示累计 L2 23.61%，各阶段低于 3%，验证了两种误差需要分别报告（`.local/final-boundary-compound-test.log`）。Windows 原阈值超限的来源及实际末层 HTP 结果仍待新一轮回传。

下一步：骁龙本运行固定入口一次，回传末层原生逐阶段误差、孤立与串联 HTP 对照、八位置 top-1。
