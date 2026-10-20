# 只读命令

以下 `service-ops` 指已解析为绝对路径的 PowerShell/Bash 入口。服务、节点和日志配置见 [topology.md](topology.md)。

`<env>` 为完整分组，例如 `domestic-prod`、`overseas-test`；旧 `dev/test/prod` 兼容国内分组。`<env> groups` 展示六个分组与策略。`servers` 包含待补资产，不代表全部已通过连接验证。

## 选择查询

| 命令 | 用途 |
|---|---|
| `<env> doctor query` | 本地工具、配置、私钥或密码配置档检查；待补地址/认证会失败，不证明 SSH 连通 |
| `<env> list` / `<env> servers` | 当前配置中的服务/节点 |
| `<env> <service> status [server]` | 服务进程观察 |
| `<env> <service> health [server] [date]` | 进程、日志元数据和近期关键词匹配行摘要；不等同就绪检查 |
| `<env> <service> logs [N] [server] [date]` | 每个候选文件末尾 N 行，默认 100；总输出受预算限制 |
| `<env> <service> grep <pattern> [N] [server] [date] [ctx]` | 单节点关键词查询，每文件最多 N 行，默认 200；总输出受预算限制 |
| `<env> <service> grepall <pattern> [N] [date] [ctx]` | 服务部署节点关键词查询 |
| `prod <service> backupgrep <pattern> [date] [server] [ctx]` | 生产备份日志查询 |
| `<env> <service> logsrange <start> <end> [pattern] [server] [date]` | 按墙上时间查询相关日志；检查跨日与轮转文件覆盖 |
| `<env> <service> count <pattern> [server] [date]` | 预算内关键词匹配行数；截断时不称总数 |
| `<env> <service> logfiles [server] [date]` | 实际候选日志文件 |
| `<env> trace <traceId> [services] [server]` | 指定逗号分隔服务或默认核心服务，覆盖已配置部署节点 |
| `<env> nginx-stats <server> [date] [domain]` | 预算内状态码及 URL 统计 |
| `<env> <server> ps / jvm [filter] / disk / mem / top / services / net` | 主机和 JVM 观察 |
| `<env> <server> nginx-config` | 固定 Nginx 配置目录中提取域名、路径、上游和 CORS，查看固定路径的目录/挂载元数据；不执行 nginx -t/-T，不读取密钥或图片，不证明配置已经加载 |
| `<env> <server> image-layout` | 对 settings.json 的 storage_roots 各取最多 200 条、深度不超过 5 的名称样本，仅输出日期分层、文件名类型和扩展名统计，不输出用户文件名或读取内容 |
| `<env> all-disk` / `<env> all-ps` | 跨节点观察；保留部分失败证据 |

日期为 `YYYYMMDD`，时间为 `YYYY-MM-DD HH:mm`。指定节点必须属于服务部署清单；不匹配时停止，不回退到另一节点。trace 不扩大到未配置服务，不因无结果推断链路不存在。文件缺失、压缩文件未读、预算截断或节点失败都要注明。

## 结果解释

| 状态 | 含义 |
|---|---|
| `OK` | 本次声明的查询范围执行完成 |
| `NO_MATCH` | 本次读取范围没有匹配；不等于服务正常 |
| `NO_LOG` | 没有可读候选日志；无法排除故障 |
| `SSH_FAILED` | 连接/认证/传输失败，保留脱敏原因 |
| `QUERY_FAILED` | 参数、读取、工具或表达式失败 |
| `PARTIAL` | 预算截断或范围/节点未覆盖，不能作完整统计 |

检查实际退出码及每节点结果，不从空终端输出判断无异常。报告采样时间、主机时区、文件范围和读取预算，关键词行数不直接折算独立错误数量。

多步诊断使用 [任务回执与证据](tasks.md)；启动失败、HTTP 502 的证据判定和停止条件见 [场景手册](diagnostic-runbooks.md)。任务状态与本表的单次查询结果分别保存，NO_MATCH 不会被替换成“服务正常”。

## 查询预算

脚本对查询设置执行时间、文件数、读取字节和输出行数限制；输出限额不能替代扫描限额。

- `SERVICE_OPS_QUERY_TIMEOUT_SECONDS`：默认 20 秒。
- `SERVICE_OPS_QUERY_MAX_BYTES`：默认 16777216 字节。
- `SERVICE_OPS_QUERY_MAX_FILES`：默认 20 个文件。
- `SERVICE_OPS_QUERY_MAX_LINES`：默认 2000 行。

预算调整需保持有界；超出时标记未覆盖。先缩小时间/节点/关键词再追加查询，不循环重试不可达节点。不调用 test `exec` 或发布动作。
