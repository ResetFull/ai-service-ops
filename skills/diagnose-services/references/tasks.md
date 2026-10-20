# 任务回执与证据

以下入口均为已解析的 PowerShell/Bash 脚本绝对路径。task 使用 Python 3.10+ 标准库，继续调用原有执行器；它不提供独立 SSH 通道。

```text
service-ops task --timeout 60 --request-id incident-123-status run domestic-test demo-app status demo-node
service-ops task status <job-id>
service-ops task evidence <job-id>
service-ops task list --limit 20
service-ops task --timeout 180 diagnose domestic-test demo-app startup --server demo-node --start "2026-10-20 16:00" --end "2026-10-20 16:05"
service-ops task --timeout 180 diagnose domestic-test demo-app http502 --server demo-node --nginx-server <明确的代理节点> --start "<开始时间>" --end "<结束时间>"
service-ops task reconcile <job-id>
```

--timeout、--request-id 必须位于 run/diagnose 等子命令之前；run 后续参数与旧入口相同。超时范围 1–3600 秒，默认 1800 秒；诊断总预算另封顶 180 秒，每个子查询最多 60 秒，原查询扫描预算仍生效。SERVICE_OPS_PYTHON 可指定 Python 绝对路径。

任务保存至 SERVICE_OPS_STATE_DIR/tasks/<job-id>，默认 Windows 使用 LOCALAPPDATA/ai-service-ops，Linux 使用 XDG_STATE_HOME/ai-service-ops。目录必须位于插件之外，重装插件不清理它。job.json 保存目标、配置指纹、阶段、releaseId 与证据引用；events.jsonl 保存阶段事件，output.txt 保存先脱敏的最多 256 KiB 输出。长单行超过 64 KiB 会丢弃并记 PARTIAL；阶段事件最多保存 200 条。凭据、手机号、身份证及 URL 查询参数按规则过滤，规则不能保证识别所有自由文本秘密；展示前仍须复核。

固定 request-id 绑定环境、目标、动作及参数。同 ID 同请求返回已有回执，**不会重放**；改参数被拒绝。更换 ID 意味着新请求，不能用于绕过 UNKNOWN。并发提交在回执落盘前可能得到 TASK_BUSY_INSPECT_BEFORE_RETRY，稍后仅查询该任务。

| 任务状态 | 解释与下一步 |
|---|---|
| RUNNING | 持有任务的本机进程仍可核对；不代表远端健康 |
| SUCCEEDED | 子命令在声明范围完成；同时查看 NO_MATCH 等查询状态 |
| PARTIAL | 日志缺失、截断、超时或诊断缺证；不能给出完整性结论 |
| FAILED | 参数、连接、工具或明确执行失败；保留证据 |
| UNKNOWN | 写操作结果未知，或原任务进程已消失；先只读核查，禁止自动重试 |

每次 SSH/SCP 前会重算所选配置和生产地址保护清单的指纹，变化即停止。任务回执记录本次调用范围，**不替代用户授权、主机权限或安全隔离**；本地文件也不是防篡改审计系统。

reconcile 只读收集 release-status；有固定 releaseId 时再执行该版本的 verify，不跟随 current.tsv。它保存观察任务引用，不把 UNKNOWN 自动转成成功，不解锁、不重试、不恢复、不回滚。运行中的任务拒绝 reconcile。普通查询和纯本地构建不触发远端核查。

单个全流程发布仍调用一次旧 all，以保持其固定发布记录贯穿构建、上传和验证。task 不接受任意 exec；明确授权的开发/测试自定义命令仍使用原受限入口。
