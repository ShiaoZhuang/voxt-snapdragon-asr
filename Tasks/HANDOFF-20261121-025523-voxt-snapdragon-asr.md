# 已固定源版本并启动 Mac 探针构建与模型准备

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-21 02:55:23 US/Pacific。

当前项目提交 `e045e79d9ea8a2fd5cb2184a4a79105cba82c756`。写入本轮检查点前的 Git 状态：

```text
## main
```

- 本轮获准继续实施。已初始化独立 main 仓库并提交原计划、任务系统、源码与资产锁、探针构建和模型准备脚本。
- Mac arm64 构建运行中。命令 ./scripts/build_upstream_probe.sh，PID 60408，.local/build-probe.log，退出码文件 .local/build-probe.exit。成功门槛为生成 llama-server。
- 同一 Mac 的模型下载运行中。命令 ./scripts/fetch_probe_models.sh，PID 60409，.local/fetch-probe.log，退出码文件 .local/fetch-probe.exit。成功门槛为 Q8_0 Target 与 BF16 探针 mmproj 的 SHA-256 均通过。
- 相邻基准仓库仍为 feat/dflash-profile-benchmark @ 6efb1212b6e1196ed1140040d9e4e3069f6cb0a8，已有 Capture.swift 修改。

下一步：实现并运行使用 Voxt 原路径的 Mac Final-only 对照
