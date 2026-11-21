# 修复骁龙 GitHub 下载遇到的 Schannel 吊销查询错误

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-21 09:45:35 US/Pacific。

当前项目提交 `0017ad5a7bc0b2d09a078d9a326fbeb2c8c83955`。写入本轮检查点前的 Git 状态：

```text
## main
 M scripts/win-arm64/fetch_veri1.ps1
```

- 骁龙端已成功 clone。截图中 curl 下载首个 Release 资产时尚无字节传输，Schannel 返回 CRYPT_E_NO_REVOCATION_CHECK（0x80092012），curl code 35。
- 下载器默认仍走完整 TLS 校验。仅遇到上述 Schannel 吊销状态不可取得或离线错误时使用 curl --ssl-revoke-best-effort 重试。保留证书链、主机名及文件 SHA-256 校验，其他错误输出 curl 原始诊断。
- Mac PowerShell 使用模拟 curl 验证正常下载、截图错误触发重试及已吊销证书仍被拒绝。骁龙实机重试未验证。现有 Veri 1 Release 使用同一批附件。无运行作业。

下一步：在骁龙已克隆目录 git pull --ff-only 后重跑 fetch_veri1.ps1
