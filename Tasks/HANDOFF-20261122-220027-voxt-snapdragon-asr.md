# 骁龙本首次源码构建停在工具检查，已验证自动发现 Visual Studio 和配套工具的改动

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-22 22:00:27 US/Pacific。

当前项目提交 `eb236b95256d8dfc03cfa39536d2865501d77254`。写入本轮检查点前的 Git 状态：

```text
## veri/native-win-arm64...origin/veri/native-win-arm64
 M Handoff.MD
 M README.md
 M scripts/win-arm64/build_native.ps1
```

- 实机截图显示成功获取 veri-1-native-arm64 并切换 eb236b9。build_native.ps1 第 16 行报告当前 PowerShell 找不到 cmake、ninja、clang、clang++ 和 go。流程尚未进入获取上游源码或编译。用户已确认 C++ 工具链安装，因此此错误不证明缺少 Visual Studio。
- 新版通过已安装的 vswhere 定位 Visual Studio ARM64 组件，调用官方 Launch-VsDevShell 初始化本会话，查找 VS 配套 CMake/Ninja/Clang 和常用独立工具安装路径，保留当前 PATH 中优先工具。-ToolchainCheck 只列工具路径和缺项，不下载或构建。
- Mac PowerShell 测试模拟普通 PowerShell、带空格的 VS 安装路径、可见与不可见 Go、ARM64 环境变量，确认零构建预检行为。重复跑固定版本获取、Go 评测器 Windows ARM64 编译和模拟 CMake 流程通过。真实 Windows 已安装组件及 Go 可用性待骁龙端复测。
- Handoff.MD 版本更新为 fixed tag `veri-1-native-toolchain`。没有新的 EXE 或模型下载。

下一步：切换 veri-1-native-toolchain 标签，先让新版脚本检查实际可用的工具，再编译和复验
