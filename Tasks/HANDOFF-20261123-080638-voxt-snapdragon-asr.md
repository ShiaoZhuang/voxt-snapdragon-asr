# 骁龙完整八位置 FFN 已通过，开始真实 attention 和 KV 回放

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-23 08:06:38 US/Pacific。

当前项目提交 `5a1522a946c35811bf80ab2bf793ad7dceb70e80`。写入本轮检查点前的 Git 状态：

```text
## experiment/real-qnn-replay...origin/experiment/real-qnn-replay
```

- 骁龙本 2026-11-24 00:01 Asia/Shanghai，在 `5a1522a` 运行固定入口总体 PASS，安装模型、WAV 哈希、原生 ARM64 构建、Adreno 八位置 109–116 捕获、转录均通过。
- 完整 FFN 重编码相对 dense Q8_0 的 L2 误差 1.0754%。HTP 相对同图 CPU 的 max/P95 误差 4/1 步，超过 2 步 5/16,384，L2 误差 0.0354%，最大误差占参考峰值 0.0125%，均在该完整子图门槛内。QAIRT execute 事件 216，正常退出。
- 30 次主机热态往返中位数/P95 为 1.604/1.756 ms。阶段通过范围覆盖从 FFN norm 输出到该层 down 投影输出。

下一步：捕获第 0 层 post-RoPE Q、已有 KV 与原始因果掩码，准备同一个验收入口中的 attention 验证。
