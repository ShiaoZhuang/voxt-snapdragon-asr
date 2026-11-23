# 骁龙实机已通过 ARM64 Python 与依赖预检，HTP 投影输出最大偏差 32 步，已加数值和执行对照

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-23 06:11:44 US/Pacific。

当前项目提交 `9ff331834127aace2595d0f66ff80321e284079a`。写入本轮检查点前的 Git 状态：

```text
## veri/native-win-arm64...origin/veri/native-win-arm64
 M Handoff.MD
 M scripts/win-arm64/current_handoff.ps1
 M tools/qnn-probe/projection.py
```

- 用户截图的 Windows 实机提交为 `9ff3318`。选用了原生 Win ARM64 CPython 3.12.13，QNN Python dependencies 为 PASS。默认投影的最大误差是 32 个量化步长，超过 2 步门槛，同一进程随后退出 `-1073741819 (0xC0000005)`。该版本在误差超标时先抛出异常，截图没有 QAIRT 执行证据，崩溃位置未定位。
- 新一轮固定入口保留默认 HTP 对照，新增关闭 MatMul LUT 与扩大 A16 编码范围两种设置。后者把输入编码离零点的距离扩大 4096 倍并反向调整 scale，实数输入、权重和输出量化完全相同。Win 端只做小型投影 CPU 参考，沿用已验收的 ASR CPU/GPU 基线。
- 数值失败仍完成 ORT profile 并在 native 对象清理前原子保存 JSON。报告保留最大误差、P95、超限个数、输出编码步距、QAIRT 后端执行事件和每组退出状态。HTP 每组使用独立进程。通过仍要求最大误差不超过 2 步、存在 QAIRT 后端 execute 事件和进程正常退出。
- Mac 上 ORT 1.29.0 CPU 的默认和扩大 A16 版本均为 49,152 个输出零误差。模拟覆盖数值失败且保留 profile、排除 host 事件、原生清理异常后 JSON 仍可读取、某组崩溃继续下一组、CPU fallback 不通过。设备端三组精度和稳定性仍待验证。

下一步：骁龙本运行固定入口 update_and_verify.ps1，回传三组 HTP 的误差、QAIRT 执行事件及进程退出状态。
