# 测试环境操作

以下 `service-ops` 指已解析为绝对路径的 PowerShell/Bash 入口。自动发布链路限测试分组；开发只承接明确指定的节点命令，生产全部只读。

本页以 `test` 为命令示例；其他测试清单使用其对应的完整环境名，命名规则见 [配置说明](../../../docs/configuration.md)。开发环境只承接明确授权的节点 `exec`，不自动套用测试构建。生产环境全部只读；复制已登记的生产地址到其他清单也不能绕过写入保护。

## 动作与授权

| 命令 | 行为 |
|---|---|
| `test doctor deploy` | 本地依赖与配置检查，不证明 SSH 连通 |
| `test <service> plan` | 展示源码路径、分支/SHA、dirty 状态、类型、产物、目标及验证条件 |
| `test <service> build` | 构建并保存产物快照与发布记录 |
| `test <service> upload` | 验证源码/产物身份，再上传并切换 |
| `test <service> restart` | 后端运行配置的重启方式；静态前端无需重启 |
| `test <service> verify` | 检查产物身份、进程和已配置就绪 URL；前端还核对 HTTP releaseId |
| `test <service> verify <releaseId>` | 固定历史发布记录核对身份，不跟随本地 current 索引 |
| `test <service> release-status` | 只读核对远端已切换产物及 previous 发布记录，不等同 JVM 就绪验证 |
| `test <service> all` | 预检后 build → upload → restart → verify |
| `test <service> rollback <releaseId>` | 恢复指定发布记录对应的版本并验证；需回滚授权 |
| `test <server> exec <command>` | 仅执行用户明确给出的测试节点和命令 |

已有授权在当前任务持续有效。预检不授权写入；上传不授权重启；发布不默认授权回滚、首次目录迁移或任意自定义命令。prod 写动作和 `exec` 必须失败。当前实现对多节点写入明确停止，不能静默只发布第一节点。

## 配置与构建

通用服务字段后追加 `repo|module|dir|artifact|deployMode|kind|verifyUrl|packageManager`；旧 10 字段默认 `kind=jar`。包管理器版本和服务数量从配置读取。

- `jar`：按 settings.json 的 maven_profile 构建，默认 test，默认运行构建测试；产物为模块 target 中的配置 JAR，重启模式为 `script` 或 `stopstart`。
- `frontend`：使用配置中白名单化的 `npm` 或固定 `pnpm@版本`，执行 `npm ci` 或 Corepack `install --frozen-lockfile`，再执行 settings.json 的 frontend_build_script，默认 build:test。
- 安装失败或 manifest/lockfile 不同步时停止，不用 `--force`、`--no-frozen-lockfile`、`npm install` 或改版本绕过。
- `SERVICE_OPS_WS` 指定工作区，兼容 `SERVER_OPS_WS`。缺工作区或来源不明时停止，不使用旧产物补位。
- 已授权的开发、测试操作不因源码未提交额外询问，不要求 `SERVICE_OPS_ALLOW_DIRTY`。发布记录仍如实记录 dirty 状态与源码指纹，构建后源码变化立即停止；生产始终只读。

## 发布记录

`SERVICE_OPS_STATE_DIR` 可指定本机状态目录，默认使用用户数据目录，不向业务仓库写发布状态。记录和快照按服务/releaseId 保存；跨 PowerShell/Bash 共享记录或并行构建时，必须显式使用同一状态目录，以共享本地构建锁。

默认测试清单使用 `test/<service>`，另一组测试清单使用 `overseas-test/<service>`；manifest 环境必须与分组一致，不混用 current 或历史快照。

manifest 使用 UTF-8/LF TSV，每行 `key<TAB>value`，保存环境、服务、类型、源码绝对路径、分支/SHA、dirty 状态、source_fingerprint、构建 profile、releaseId、产物 SHA-256、目标节点和时间。source_fingerprint 覆盖 Git 状态、已跟踪文件差异和未忽略的未跟踪文件哈希；构建前后必须一致，不能把构建期间变化的源码记为已验证版本。

build 形成不可变快照；同一构建目录的构建与快照步骤使用本地锁，冲突时停止。all 固定自身构建返回的发布记录，贯穿上传和验证；current.tsv 只是最近构建的本地索引，不表示远端正在运行的版本。单独 upload 读取索引一次，固定对应记录，再核对源码身份及快照哈希，不从任意 dist/target 猜测本次版本。

## 远端布局与失败恢复

前端将内容保存到独立 release 目录，通过软链接入口的一次 rename 切换。每个 release 提供 `service-ops-release.txt`；HTTP 返回内容必须与预期 releaseId 一致。现有发布入口若是真实目录，预检返回 `LAYOUT_MIGRATION_REQUIRED`，在上传前停止。首次迁移需要独立明确请求和目录/Nginx 只读确认，不在普通发布中自动搬动目录。

后端使用唯一上传临时文件、哈希校验和可恢复版本。上传、切换、重启和回滚需有明确锁归属；并发竞争报告忙，不接管可能仍运行的发布。异常遗留锁先核对持有者和发布状态，不凭时间经过就删除。

失败立即停止后续写动作，保留失败阶段、已切换版本和恢复证据。验证失败不自动回滚；授权回滚后恢复指定版本并再次检查。不要递归清理历史版本以解锁或腾空间。

写入的 SSH/SCP 返回超时、137 或 255 时不能判定远端已停止，返回 UNKNOWN 并保留锁；明确完成的失败才按原规则释放所持锁。使用 [任务回执](../../diagnose-services/references/tasks.md) 固定 request-id、保存阶段和脱敏证据。reconcile 仅补充只读观察，不自动解除 UNKNOWN 或解锁。

用户要求“回滚上一版”时，先通过 release-status 核对远端 current/previous 的实际切换记录，再对应本地历史 manifest 与快照，选择明确 releaseId；不要用最近构建时间推断上一运行版本。没有受管历史记录或本地快照时报告缺失，不猜测版本或直接覆盖目录。

## 验证与完成条件

完整 all 在构建/写入前检查必需验证 URL，缺失时停止；不猜测生产/测试端口或修改业务配置。verify 缺测必须报告 UNKNOWN/不完整，不能成功包装。

后端必须核对远端 JAR 哈希、准确对应产物路径的唯一 Java 进程、重启前后的进程身份和已配置就绪探测；缺 JAR、旧进程残留、多进程、启动超时、错误进程或探测失败均不能通过。前端必须核对发布记录、逐文件哈希和 HTTP releaseId，HTTP 200 本身不足以证明新版本上线。

最终分别报告产物切换、进程启动、就绪探测及版本身份的结果。近期日志只能辅助定位，不使用历史 ERROR 关键词数量判定本次发布成败。测试编译通过不等于服务或业务验收通过。VPN/SSH 不可达时报告网络前提，不循环重试。
