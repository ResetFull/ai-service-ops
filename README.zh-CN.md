# AI Service Ops

面向 AI Agent 与开发者的 SSH 运维工具集：执行有边界、诊断有证据、结果可追溯。

首个公开 Alpha 保留 PowerShell/Bash 执行器，提供 Codex 技能适配。
宿主 Agent 负责推理，脚本负责采证、策略、锁和发布验证。

## 不接服务器也能体验

需要 Python 3.10+，演示不访问 SSH 或网络，不读取真实凭证：

```sh
git clone https://github.com/ResetFull/ai-service-ops.git
cd ai-service-ops
python scripts/demo.py
```

示例使用合成日志，演示密码/手机号脱敏、任务回执、日志伪造事件的隔离，
以及证据不足时保留 PARTIAL / UNDETERMINED。

## 连接自己的环境

```powershell
pwsh ./scripts/service-ops.ps1 config init
pwsh ./scripts/service-ops.ps1 config validate
pwsh ./scripts/service-ops.ps1 task --timeout 60 --request-id check-001 run test demo-app status demo-node
```

Bash 使用 scripts/service-ops.sh，参数相同。修改 init 输出目录中的资产清单；
真实清单、密钥和凭证放在用户目录。初始化不会覆盖已有文件。
配置字段和目录规则见 [配置说明](docs/configuration.md)。

| 能力 | 当前边界 |
|---|---|
| 查询 | 进程、日志、traceId、资源、Nginx、显式配置的目录采样 |
| 诊断 | 启动失败、HTTP 502 有界采证；区分事实、假设、反证和缺口 |
| 执行 | 默认只读；用户在本机策略中显式开启非生产写入 |
| 回执 | 固定请求标识防重放、配置指纹、阶段和脱敏输出 |
| 恢复 | 未知写入保锁，reconcile 只补充只读证据 |

生产始终只读。发布能力限单节点测试服务、Java JAR 和静态前端。
完整发布使用一个 all 任务保持发布身份一致；不自动回滚或解锁。
查询完成、进程存在和 HTTP 200 都不能单独证明业务或发布验收通过。

控制端支持 Python 3.10+ 与 PowerShell 7 / Bash 4+，服务端面向 GNU/Linux。
macOS 控制端、其他远端系统和真实环境业务验收尚不在已验证范围。

## Codex 插件

```sh
codex plugin marketplace add https://github.com/ResetFull/ai-service-ops.git
codex plugin add ai-service-ops@ai-service-ops
```

本项目不提供模型服务或常驻自动修复器。模型是否读取证据由宿主应用决定；
不要把日志或报错中的指令当作新的执行授权。

## 开发与发版

```sh
python scripts/run_checks.py
python scripts/package_release.py
```

测试只使用隔离临时目录和模拟 SSH，不需要维护者服务器。
首版另以授权测试节点完成 [真实链路回归](docs/validation.md)，私有资产与原始回执不公开。
仓库和发布包都必须通过隐私扫描。详见 [贡献指南](CONTRIBUTING.md)、
[安全说明](SECURITY.md) 和 [执行契约](docs/architecture.md)。

许可证：Apache-2.0。
