# OpenCL 初始化空指针已修复并交叉编译，6.2 MB ARM64 运行时补丁已上传，等待骁龙复验

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-22 18:28:42 US/Pacific。

当前项目提交 `41c20c64709f009c2f295c83afe2b58001c498a8`。写入本轮检查点前的 Git 状态：

```text
## diagnose/veri-1-opencl-startup...origin/diagnose/veri-1-opencl-startup [ahead 1]
 M Handoff.MD
 M Tasks/INDEX.md
 M Tasks/TASK-20261121-voxt-snapdragon-asr.md
 M scripts/win-arm64/fetch_veri1.ps1
 M scripts/win-arm64/run_verify.ps1
?? Tasks/HANDOFF-20261122-182525-voxt-snapdragon-asr.md
?? scripts/win-arm64/veri1-opencl-fix.json
```

- Windows 探针和 Event 1000 匹配 PID 8952，PE 偏移 0x4b8ab8。对应 `ggml_backend_opencl_buffer_type_get_alignment` 读取还为空的 backend_ctx。模型缓冲区规划在 OpenCL 队列初始化前调用 getter。
- 修复源码提交 `41c20c64709f009c2f295c83afe2b58001c498a8`，改从已枚举的每设备属性读取 alignment 和 max size，量化内存规划用相同的 alignment，保留 OpenCL 队列延迟初始化。Mac 用实际三个 getter 组成 UBSan 测试，在两个空 backend_ctx 的 mock 设备上验证不同对齐和上限、FP16 与量化 buffer size。
- `scripts/win-arm64/build_on_mac.sh` 成功（退出 0）。输出 `build/windows-arm64-10a9b7c26148/bin/qwen3_asr_server.exe`，验证 PE 原生 ARM64 以及导入 DLL 列表和 Veri 1 一致（包括 OpenCL.dll）。SHA-256 `5d1c2055e3f7569caade1e700032454ab64981d8ec88e2bc9f004cba18fc94b6`。
- Veri 1 Release 新增 `veri1-opencl-fix-arm64.zip`（6,241,449 bytes），GitHub 上传状态 uploaded，远端 SHA-256 与源码清单一致。新的 EXE 和原版并排，脚本对包和 EXE 均校验 SHA-256。模型、驱动、原版 EXE 和基准资产复用。Mac PowerShell mock 验证了真实 ZIP 安装、缓存、损坏恢复、SHA 拦截、四组 runner 使用指定 EXE 与报告记录版本。
- 根目录 Handoff.MD 记录固定标签复验命令。本机没有目标 Adreno，机器端启动和推理结果未验。复验以同机 CPU/OpenCL 四组通过，OpenCL 有 DFlash 接收且逐 token 对齐为门槛。

下一步：按 Handoff.MD 获取 veri-1-opencl-fix 标签，在骁龙本使用原 Veri 1 模型完成四组 Quick 并回传报告
