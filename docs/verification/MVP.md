# MVP 实施与验收记录

## 分阶段计划

1. 服务端：D1、双 Token、事务上传与删除、只读 MCP；使用合成数据验证。
2. iOS：SwiftUI 工程、Keychain、独立共享同意、HealthKit 分页增量和核心页面。
3. 部署：核对账号与专属资源，迁移部署，通过 HTTPS 和 MCP SDK 客户端验收。
4. 真机：系统授权由用户完成，验证回填、增量、删除、撤回及失败恢复；记录后台观察条件。

## 关键失败模式与边界

- 未鉴权、错 Token、两种 Token 交叉使用、两种 Secret 相同或缺失时拒绝服务。
- 请求流超过 10 MiB、数组超限、非法 UUID/类型/单位/数值/时间、重复与冲突 UUID。
- 整批事务失败不能部分提交；重复上传幂等；删除与新增冲突时删除优先。
- 删除最后一个样本后统计必须归零；全部删除不能遗留状态。
- 时间使用半开区间，拒绝无时区时间、无效日期和颠倒范围；按样本时区分桶。
- 睡眠多来源与同来源重叠去重、18 时边界、跨午夜和夏令时偏移。
- MCP 仅注册四个只读工具；验证真实协议初始化和工具调用。
- iOS：未同意/已撤回/关闭类型禁止上传，撤回取消在途任务；网络或部分批次失败不推进 anchor。
- 服务端/范围切换重置相应 anchor；删除服务器数据只同步之后的新数据；锁屏和后台预算结束保留检查点。
- 系统不报告健康读取授权结果，空数据不得声称用户拒绝授权。

## 初始检查

- 仓库干净，仅有 Worker 存活检查，无 D1、MCP 或 Xcode 工程。
- Xcode 27.2；iPhone 17 已配对且 available。
- 存在 Apple Development 有效签名身份及一张已撤销旧身份，签名不得使用旧身份。
- Cloudflare 插件仅返回一个账号。后续仅使用 healthbridge 专属资源。

## 验收状态

已完成下列实施与验收。真机删除按用户要求跳过；长期后台与整夜锁屏仍待观察。

## 实施结果（2026-11-03）

- Worker `healthbridge` 和专属 D1 `healthbridge` 已部署在唯一确认的 Cloudflare 账号中。既有项目资源未更改。
- HTTPS 根地址：<https://healthbridge.waterhydroxyl.workers.dev>；MCP：<https://healthbridge.waterhydroxyl.workers.dev/mcp>。
- D1 已应用 `0001_init.sql`，同步写入 Wrangler 迁移登记表，避免后续 CLI 重复应用。
- 两个随机 Token 作为 Worker Secrets 保存，本机凭据保存在 macOS Keychain 的 `HealthBridge deployment` 服务下；未写入代码、Git 或聊天。部署传递使用临时公钥加密，临时传递密钥已删除。
- iPhone App ID：`app.yiliang.healthbridge`。有效开发证书及其私钥完成真实代码签名；专属描述文件包含本机配对设备、HealthKit 和 Background Delivery。已撤销的旧证书未使用。
- Apple 最初以未接受最新开发者协议拒绝签名，用户确认接受后正常自动签名成功。没有撤销或替换其他项目证书。

## 验收证据

| 项目               | 结果与证据边界                                                                                                                                          |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 服务端检查         | `npm run check` 通过，26 项 Workers 运行时测试通过，类型检查和部署打包通过                                                                              |
| 输入与安全         | 两种 Token 交叉调用被拒绝；非法样本整批拒绝；JSON/请求大小/数量上限、时间区间、来源重叠和 D1 整批回滚已测试                                             |
| HTTPS 合成数据闭环 | `scripts/verify-live.mjs` 对真实地址验证鉴权、重复上传幂等、D1 存储和查询，并清理自身合成 UUID                                                          |
| MCP 真实客户端     | 官方 MCP SDK v2 Client 完成 Streamable HTTP 初始化、listTools 和四个工具调用，只注册四个只读工具                                                        |
| iOS 自动化         | 14 项 XCTest 通过：10 项连接、共享和 checkpoint 测试，4 项多页面 UI 场景测试                                                                            |
| 实际页面           | 引导、无效地址、概览、7/30 天详情、设置、隐私、空数据、本机模式、进度、失败、暂停、锁屏提示、深色和无障碍大字体均运行过；模拟状态使用显著标记的合成数据 |
| 视觉修复           | 修复概览内小图表拦截卡片点击；无障碍大字体改为可读数值卡片，详情保留图表和表格，避免轴标签重叠                                                          |
| 真机读取与首次同步 | 用户亲自选择共享范围、完成系统健康授权；五种类型均已从该 iPhone 上传到 D1，MCP 查询验证可读                                                             |
| 真机新增事件       | 用户手动创建的单条 17 步测试记录已通过增量同步到 D1，并经 MCP 精确识别；样本 UUID 仅在验证进程内存中使用                                                |
| 真机删除事件       | **未验证，用户明确要求跳过。** 用户表示 Apple 健康无法删除该条测试记录，因此停止操作；不声称它已删除或清理                                              |
| 撤回与恢复共享     | 用户在真机操作后明确确认：撤回显示暂停，重新同意后恢复。属于用户操作确认，非代理自动化截图证据                                                          |
| 断网与恢复         | 用户在真机确认断网立即同步出现未完成提示，恢复网络后同步正常；随后真实 MCP 查询成功并观察到后续上传                                                     |
| 签名与安装         | 真机自动签名构建成功，`codesign --verify --deep --strict` 通过，安装到配对 iPhone 并成功启动。原 App 数据保留                                           |

原始健康样本没有进入聊天、日志、Git、截图或测试文件。真实查询仅在进程内验证，输出类型计数和布尔结果。仓库截图全部来自标有“界面测试 · 合成数据”的模拟器场景。

### 可复查的界面证据

- [本机概览](screenshots/03-local-overview.png)
- [30 天详情](screenshots/04-detail-30-days.png)
- [空数据](screenshots/07-empty.png)
- [失败恢复提示](screenshots/09-failure.png)
- [锁屏等待提示](screenshots/10-lock-wait.png)
- [同步进度](screenshots/11-progress.png)
- [撤回暂停](screenshots/12-paused.png)
- [深色大字体](screenshots/13-dark-large-text.png)

## 剩余限制和观察条件

1. Apple 健康删除事件的真机验收按用户要求跳过。服务端删除、批次中删除优先、最后样本删除后的状态归零、删除确认后的 checkpoint 已自动测试。
2. 未进行整夜锁屏与长期后台观察。条件应为：真机已授权、允许共享、App 未被上划关闭、Apple Watch 数据已回传、记录锁屏和解锁时间；早上解锁后观察是否补齐，并检查 MCP 新鲜度。**模拟器的锁屏提示截图不证明 HealthKit 后台交付已通过。**
3. iOS 后台调度没有固定时延保证。本次用户操作验证的是前台恢复；不能承诺每次解锁后特定分钟内补齐。
4. 官方 MCP SDK 客户端已验证，README 的 Codex/Claude Code 配置按当前官方文档编写；没有声称已在每个商业客户端完成安装。仅支持 OAuth 的连接器不在本 MVP 范围。
5. 概览使用每日数值与 7/30 天趋势，服务端提供睡眠分期汇总；未照搬原型中所有装饰和更复杂的睡眠阶段/心率区间图。
6. 后续按用户授权创建了公开仓库并接入一键部署，现以 README 的快速连接流程为准。最初验收时尚无 remote。
7. 不包含 App Store/TestFlight 发布、审核与隐私标签合规验收。

## 官方接口核对

- [Apple Anchored Object Query](https://developer.apple.com/documentation/healthkit/hkanchoredobjectquery)
- [Apple Observer Query](https://developer.apple.com/documentation/healthkit/hkobserverquery)
- [Apple Background Delivery](<https://developer.apple.com/documentation/healthkit/hkhealthstore/enablebackgrounddelivery(for:frequency:withcompletion:)>)
- [D1 事务批量执行](https://developers.cloudflare.com/d1/worker-api/d1-database/)
- [Cloudflare MCP Streamable HTTP](https://developers.cloudflare.com/agents/model-context-protocol/protocol/transport/)
- [Codex MCP 配置](https://learn.chatgpt.com/docs/extend/mcp)
- [Claude Code MCP 配置](https://code.claude.com/docs/en/mcp)

## Token 初始化与 Agent 快捷复制增量（2026-11-03）

- 初始化页可使用 `SecRandomCopyBytes` 生成两枚独立的 256 位 Token。整组草稿写入独立 Keychain 条目，关闭后可恢复；生成或取消不会改变正在使用的上传 Token。
- 用户分别复制到 Cloudflare Secrets 并部署后，在 App 测试写入连接和可选的 MCP 只读初始化，成功后才启用。没有新增未认证的服务端初始化接口，没有轮换现有部署的 Secrets。
- 沿用旧版写入 Token 的 Keychain service/account；MCP Token 使用独立 service，并以规范化服务器 origin 为 account。生成草稿、写入和只读凭据互相分离。
- “连接 AI Agent”支持导入并验证 MCP Token、复制地址和只读 Token、复制 Codex TOML / Claude Code JSON / 通用 JSON。预览始终使用占位符，是否将只读 Token 放进剪贴板由用户选项控制，绝不导出写入 Token。
- 复制设置 2 分钟剪贴板有效期，允许通用剪贴板。断开连接清除当前服务器在 App 中保存的写入和只读 Token，保留独立的未使用生成草稿。
- 测试发现同一表单中两个保密输入框会出现相同值联动，已将可选只读 Token 改成单独填写弹窗；复测了原来的非法地址提示及“继续”不可用状态。

验证结果：

- **22 项 XCTest 全部通过**，其中新增 6 项凭据逻辑测试和 2 项用户流程测试；覆盖安全生成、Keychain 恢复/隔离/删除、输入校验、配置内容、JSON/SSE 初始化回复、复制、草稿恢复与只读导入。
- 使用 App 同一份 `ServerAPI.swift` / `MCPConnection.swift` 请求真实部署，MCP Token 初始化成功，写入 Token 被 MCP 入口拒绝；不调用健康查询工具。该项为原生 Swift 网络代码验证，不冒充真机 UI 验收。
- App 生成的合成凭据配置通过 Python `tomllib` 和 JSON 解析验证，包含精确的只读 Authorization 值；修复了 JSONEncoder 默认斜杠转义不适用于 TOML 的问题。
- 真机自动签名构建、代码签名校验、覆盖安装和启动成功，保留原数据与上传凭据。
- UI 自动化的网络回复和凭据均为合成数据，使用独立测试 Keychain namespace；网络替身只编译在 Debug 模拟器中。
- 模拟器在部分键盘/导航切换时仍报告没有源码定位的 `Invalid frame dimension` 警告。相关交互测试通过，实际截图未见负尺寸或布局溢出；未将这些告警描述为已修复。

界面证据：[生成 Token](screenshots/15-token-generation.png)、[使用生成草稿](screenshots/16-generated-connection.png)、[保存只读 Token](screenshots/17-agent-token.png)、[复制完整配置](screenshots/18-agent-copy.png)。截图不含可用于真实服务的凭据。

用户已在安装后的真机 Agent 页导入原 MCP Token，并明确确认“验证保存成功，复制正常”。该项为用户操作验收，未读取或输出手机中的 Token；现有服务器 Secrets 未轮换。
