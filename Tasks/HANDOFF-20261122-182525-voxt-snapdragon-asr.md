# 已定位 OpenCL 缓冲区规划空指针，Windows ARM64 修复版正在交叉编译

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-22 18:25:25 US/Pacific。

当前项目提交 `afc82535f16d4caa850ea9df829967dcaaa6850a`。写入本轮检查点前的 Git 状态：

```text
## diagnose/veri-1-opencl-startup...origin/diagnose/veri-1-opencl-startup
 M patches/llama-voxt.patch
```

- Windows PowerShell 5.1 启动探针 2026-11-23 10:22 +08:00。受监督服务 PID 8952（0x22f8），系统 Application Error 1000 同 PID，故障模块 `qwen3_asr_server.exe`、异常 `0xC0000005`、模块偏移 `0x4b8ab8`。OpenCL 驱动设备枚举和音频投影器头部读取在此前完成。
- 发布 PE ImageBase 0x140000000，`llvm-addr2line` 将 0x1404b8ab8 定位到 `ggml_backend_opencl_buffer_type_get_alignment`。反汇编匹配 `dev_ctx->backend_ctx->alignment`，而设备枚举将 backend_ctx 初始化为空，分配规划先读取 alignment。相邻 max size 和量化 allocation size getter 有同一先后依赖。
- 补丁将内存对齐、最大单次分配大小移到设备能力阶段读取；三个 getter 使用已建立的每设备属性，队列初始化仍延后。固定源码完整 patch dry-run 已过。
- Mac 交叉编译已启动，`scripts/win-arm64/build_on_mac.sh`（进程会话 53529），日志 `.local/windows-arm64-opencl-fix.log`，结束码 `.local/windows-arm64-opencl-fix.exit`。完成门槛为交叉编译退出 0、验证 ARM64 PE 及 OpenCL 导入，并只提供小型二进制更新。

下一步：编译完成后检查 ARM64 EXE 并发布仅含运行时补丁的实机快测交接
