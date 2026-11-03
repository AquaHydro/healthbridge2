# HealthBridge 开发方案（方案 A：用户自部署）

> 版本：v0.1 · 2026-11-03 · 状态：待审查（Codex）
> 名称 HealthBridge 为暂定工程名，上架名称待定。

## 1. 背景

Apple 健康（HealthKit）没有云端 API，数据只存在用户的 iPhone 上。个人 AI Agent（Claude Code、Codex、其它 MCP 客户端）没法直接读取睡眠、心率等数据，健康管理类对话缺少事实依据。

目标是做一个 iOS App，在后台把 HealthKit 数据增量同步到**用户自己 Cloudflare 账号里的 Worker**，再由这个 Worker 提供 MCP 服务，让 Agent 按需查询。

先满足开发者自用，同一套代码随后上架 App Store，面向会用 Cloudflare 的技术用户。

### 1.1 方案选型与决策记录

先后评估过三种方案：

| | 方案 0：第三方 App 导出 | **方案 A：用户自部署（采用）** | 方案 B：开发者统一托管 |
|---|---|---|---|
| 做法 | 用现成 App（如 Health Auto Export）定时 POST 到自建接口，只写服务端 | 自研 App；用户在自己的 Cloudflare 账号部署 Worker，App 填写地址和 Token | 自研 App；开发者运营一个多用户的 Cloudflare 服务，用户用 Sign in with Apple 登录 |
| 数据存放 | 用户自己的服务器 | 用户自己的 Cloudflare 账号 | 开发者的 Cloudflare 账号 |
| 用户门槛 | 需要购买第三方 App，自己部署服务端 | 需要 Cloudflare 账号，点一次部署按钮 | 最低：登录即可用 |
| 开发量 | 最小 | 中 | 大 |
| 合规负担 | 无（不上架） | 轻 | 重 |
| 能否上架 | 不适用 | 可以 | 可以 |
| 结论 | **否决**：要求独立开发、可上架 | **本期采用** | **暂缓**，作为后续演进方向 |

#### 方案 B 详细分析（暂缓，保留作为演进方向）

**架构差异**
- **账号**：用 Sign in with Apple 登录，Worker 签发会话 Token；App 用会话 Token 调用 `/v1/ingest`。
- **数据隔离**：所有表增加 `user_id` 列，所有查询强制按 `user_id` 过滤。也可以每个用户一个 Durable Object（自带 SQLite），天然隔离，但运维更复杂。
- **MCP 鉴权**：必须改用 OAuth（`@cloudflare/workers-oauth-provider`）。用户在 Agent 里添加连接器后，跳转到 Apple 登录并授权；每个 Agent 单独授权，可单独撤销。
- **加密**：静态存储之外，可考虑按用户的应用层加密（每个用户一把密钥），降低整库泄露的影响。
- **App**：增加登录 / 登出、账号删除；保留「自部署」作为高级选项，两种模式共存。

**合规与审核负担（暂缓的主要原因）**
- **PIPL**：健康数据属于敏感个人信息，需要单独同意，并做个人信息保护影响评估。Cloudflare 的存储在境外，向中国大陆用户提供服务会涉及个人信息出境，需按标准合同或认证等路径处理。
- **GDPR**：健康数据是第 9 条规定的特殊类别数据，需要明示同意，处理记录和数据主体权利（导出、删除）都要落实。
- **App Store**：
  - 5.1.1(v)：支持注册账号的 App 必须能在 App 内删除账号，并删除服务端数据。
  - 隐私标签必须申报「健康与健身」类数据，并标注为与用户身份关联。
  - 5.1.2(i) 的第三方 AI 同意要求同样适用。
- **安全责任**：一旦发生数据泄露，开发者是数据处理者，要承担通知和法律责任。

**成本与运营**
- Cloudflare 的 Workers、D1 / Durable Objects 费用随用户量增长，由开发者承担，需要订阅收费（应用内购买）来覆盖。
- 需要提供客服、故障响应和数据导出，并持续维护隐私政策。

**从 A 演进到 B 的路径**（A 的设计已为此预留）
1. 数据库迁移：`samples`、`meta` 增加 `user_id` 列，主键改为 `(user_id, uuid)`。
2. 鉴权中间件：从「比较固定 Token」改为「解析会话 / OAuth Token 得到 `user_id`」。HTTP 接口和 MCP 工具的逻辑不变。
3. App：在引导流程第 ② 步增加「使用托管服务（登录）」选项，同步引擎不用改。
4. 开源的自部署版继续保留，作为注重隐私用户的选项。

**启动方案 B 的条件**（满足其一再评估）：出现大量非技术用户的需求；有明确的收费模式能覆盖合规和运营成本；或计划进入中国大陆市场，需要做境内部署。

#### 选择方案 A 的理由
- 开发者不托管任何用户健康数据，避开上面列出的 PIPL、数据出境、GDPR 等托管合规负担。
- 服务端是单用户模型，不需要账号体系和多租户隔离。
- 自用版与上架版是同一套代码，区别只在 App 的引导与合规界面。
- 演进到方案 B 时，Worker 代码和 App 同步引擎可以复用。

## 2. 目标与非目标

**目标**
- G1：iPhone 在后台增量同步 HealthKit 数据，支持新增与删除，并且幂等。
- G2：Worker 存储数据，提供 MCP 工具，供 Agent 查询原始样本、聚合统计、睡眠汇总和同步状态。
- G3：用户点一次「Deploy to Cloudflare」即可部署自己的服务端。
- G4：App 满足 App Store 审核要求（第 5 节）。

**非目标（本期不做）**
- 秒级实时同步。iOS 机制做不到，见 3.3。
- 多用户 / 托管服务（方案 B）。
- MCP OAuth：本期只用 Bearer Token；要接入 claude.ai / ChatGPT 连接器时再加。
- 向 HealthKit 写入数据、Apple Watch App、Android。
- 服务端可视化面板：数据概览放在 App 内。

## 3. 总体架构

```
┌──────────── iPhone ────────────┐        ┌──────── 用户的 Cloudflare 账号 ────────┐
│ HealthKit                      │        │ Worker (health-mcp)                    │
│   │ HKObserverQuery            │ HTTPS  │   POST   /v1/ingest   (INGEST_TOKEN)   │
│   │ + Background Delivery      │──────▶ │   GET    /v1/ping     (INGEST_TOKEN)   │
│   ▼                            │        │   DELETE /v1/data     (INGEST_TOKEN)   │
│ HKAnchoredObjectQuery 增量     │        │   ALL    /mcp         (MCP_TOKEN)      │
│   ▼                            │        │            │                           │
│ 批量上传，成功后才推进 anchor  │        │            ▼                           │
└────────────────────────────────┘        │   D1 (SQLite): samples, meta           │
                                          └────────────────────────────────────────┘
                                                        ▲
                                     Personal Agent ────┘ MCP over Streamable HTTP
```

### 3.1 仓库结构（monorepo）

```
healthbridge/
├── server/            # Cloudflare Worker（TypeScript）
│   ├── src/index.ts
│   ├── migrations/0001_init.sql
│   ├── wrangler.jsonc
│   └── test/
├── ios/               # Xcode 工程（SwiftUI）
│   └── HealthBridge/
├── docs/              # 本文档、隐私政策、审核说明
└── README.md          # 含 Deploy to Cloudflare 按钮
```

### 3.2 两个 Token，权限分开

| Secret | 持有方 | 权限 |
|---|---|---|
| `INGEST_TOKEN` | iOS App（Keychain） | 写入、删除、连通性测试 |
| `MCP_TOKEN` | Agent 配置；App 可按服务器存入独立 Keychain 条目，用于主动复制 | 只读查询 |

Agent 侧的 Token 泄露时，最多被读走数据，不能篡改或删除；App 侧同理。两个 Token 都通过 `wrangler secret` 设置，比较时用 `crypto.subtle.timingSafeEqual`。

### 3.3 时效性的客观限制（写进 App 说明和 README）

- Apple Watch 的数据要先同步到 iPhone。
- iPhone 锁屏时，HealthKit 数据受数据保护加密，App 读不到；查询失败时 anchor 不推进，下次唤醒再重试。
- 后台唤醒的频率由 iOS 决定，部分类型（如步数）最高只能按小时推送。
- 被用户手动上划强杀的 App 不会再被后台唤醒，需要手动重新打开。
- 预期延迟为几分钟到一小时。夜间的睡眠数据通常在早上第一次解锁后补齐。

## 4. 服务端设计（server/）

### 4.1 技术选型
- Cloudflare Workers + D1。
- MCP：`@modelcontextprotocol/sdk` + `agents/mcp` 的 `createMcpHandler`（无状态 Streamable HTTP，不需要 Durable Object）。**实现前须按当前 Agents SDK 文档核对 API。**
- 参数校验用 `zod`。
- 测试用 `vitest` + `@cloudflare/vitest-pool-workers`。

### 4.2 数据模型

```sql
-- migrations/0001_init.sql
CREATE TABLE samples (
  uuid      TEXT PRIMARY KEY,      -- HealthKit 样本 UUID，天然幂等键
  type      TEXT NOT NULL,         -- 见 4.3
  start_ms  INTEGER NOT NULL,      -- UTC epoch 毫秒
  end_ms    INTEGER NOT NULL,
  tz_min    INTEGER NOT NULL,      -- 样本发生时的本地 UTC 偏移（分钟），用于按本地日期聚合
  value     REAL NOT NULL,         -- 数量型样本为数值；分类型样本为枚举值
  unit      TEXT,                  -- 'bpm' | 'ms' | 'count' | NULL
  source    TEXT,                  -- 来源名称，如 "Apple Watch"
  device    TEXT                   -- 来源设备型号（可空），用于睡眠去重
);
CREATE INDEX idx_samples_type_start ON samples(type, start_ms);

CREATE TABLE meta (                -- 同步状态等少量键值
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
```

**时间设计说明**：用 UTC 毫秒做区间查询，同时保存每个样本自己的 `tz_min`，按本地日期聚合时使用 `start_ms + tz_min*60000`。这样跨时区出行后，历史数据的「本地日期」也不会错位。`tz_min` 优先取样本 metadata 里的 `HKMetadataKeyTimeZone`，没有时取上传时设备在该时刻的时区偏移。

### 4.3 数据类型（MVP）

| type | HealthKit 标识 | 单位 | value 含义 |
|---|---|---|---|
| `sleep` | `HKCategoryTypeIdentifier.sleepAnalysis` | — | 0 inBed, 1 asleepUnspecified, 2 awake, 3 core, 4 deep, 5 rem |
| `heart_rate` | `.heartRate` | bpm | 心率 |
| `resting_hr` | `.restingHeartRate` | bpm | 静息心率 |
| `hrv` | `.heartRateVariabilitySDNN` | ms | HRV SDNN |
| `steps` | `.stepCount` | count | 步数 |

扩展方式：iOS 与服务端各维护一张类型映射表，新增类型只需各加一行。后续候选类型：血氧、呼吸频率、手腕温度、活动能量、体能训练（workout 需单独建表，不进本期）。

### 4.4 HTTP 接口

所有接口都需要 `Authorization: Bearer <INGEST_TOKEN>`，响应为 JSON。

**`POST /v1/ingest`**
```json
{
  "schema_version": 1,
  "added": [
    { "uuid": "…", "type": "heart_rate", "start_ms": 1762128000000, "end_ms": 1762128000000,
      "tz_min": 480, "value": 62, "unit": "bpm", "source": "Apple Watch", "device": "Watch7,1" }
  ],
  "deleted": ["uuid-1", "uuid-2"]
}
```
- `added` 用 `INSERT OR REPLACE` 写入，`deleted` 按 uuid 删除，整批放在一个 `DB.batch` 里执行。
- 单次请求最多 1000 条 `added`、5000 条 `deleted`，超出返回 413；客户端负责分批。
- 未知 `type` 或字段缺失时，整批返回 400 并说明原因。不静默丢弃，否则客户端会推进 anchor 导致丢数据。
- 写入成功后更新 `meta`：`last_ingest_at`、`last_sample_at.<type>`。
- 返回 `{ "ok": true, "added": n, "deleted": m }`。

**`GET /v1/ping`**：返回 `{ ok, version, schema_version, counts: {type: n} }`，供 App 做连接测试和状态展示。

**`DELETE /v1/data`**：清空 `samples` 和 `meta`，供 App 的「删除服务器数据」功能使用。可选 `?type=` 只删某一类。

### 4.5 MCP 工具（`/mcp`，`Authorization: Bearer <MCP_TOKEN>`）

时间参数统一接受 ISO 8601（带时区偏移）或 `YYYY-MM-DD`，后者按 `tz` 参数解释，默认用最近样本的 `tz_min`。返回内容为 JSON 文本，所有时间同时给出 UTC 和本地时间。

| 工具 | 参数 | 说明 |
|---|---|---|
| `get_sync_status` | — | 每种类型的最后样本时间、最后上传时间、样本数。**Agent 回答前应先调用，以判断数据新鲜度。** |
| `query_samples` | `type, from, to, limit≤2000` | 原始样本 |
| `aggregate` | `type, from, to, bucket: hour\|day` | 每个桶的 avg/min/max/sum/count（步数看 sum，心率看 avg/min/max） |
| `sleep_summary` | `from_date, to_date` | 按晚汇总：入睡时间、醒来时间、各阶段分钟数、总睡眠时长 |

**睡眠去重规则**（`sleep_summary` 必须处理）：iPhone 与 Watch，以及第三方睡眠 App，可能对同一晚重复记录。规则如下：
1. 「晚」的归属：按样本结束时间的本地日期，界限为本地 18:00–次日 18:00。
2. 同一晚如有来源带阶段数据（value 3/4/5），只取该来源，多个时取阶段数据最多的那个；否则取时长最长的单一来源。
3. 返回结果中注明采用了哪个 `source`。

工具描述（description）要写清楚单位、时间语义和去重规则，这是 Agent 正确使用工具的唯一依据。

### 4.6 部署（Deploy to Cloudflare）
- README 放置 Deploy to Cloudflare 按钮，自动创建 D1 并绑定。
- `package.json` 的 `deploy` 脚本：`wrangler d1 migrations apply DB --remote && wrangler deploy`。
- 两个 Token 在部署时由用户填写，或部署后执行 `wrangler secret put`。README 提供生成随机 Token 的一行命令。
- **待核实**：Deploy 按钮对 D1 迁移和 secret 提示的当前支持程度，以官方文档为准。

### 4.7 安全
- 所有路由都要鉴权；未鉴权一律返回 401，不泄露路由信息。
- 请求体大小限制为 10 MB。
- SQL 全部使用参数绑定。
- `aggregate` 的 bucket 只接受枚举值，不把用户输入拼进 SQL。
- 不记录请求体日志（健康数据不进 Workers Logs）。

## 5. iOS App 设计（ios/）

### 5.1 基本信息
- 最低版本 iOS 17，SwiftUI + Observation，不引入第三方依赖。
- Capabilities：HealthKit，勾选 Background Delivery（entitlement `com.apple.developer.healthkit.background-delivery`）。
- Info.plist：`NSHealthShareUsageDescription`，写明用途和数据去向。不申请写权限，因此不需要 `NSHealthUpdateUsageDescription`。

### 5.2 界面与流程

```
首次启动
  ① 介绍页：做什么、数据流向图、时效性说明
  ② 连接服务器：填写 Worker URL + INGEST_TOKEN → 调用 /v1/ping 测试 → 存入 Keychain
     （附「如何部署」链接，指向 README）
  ③ 数据共享同意页（单独一页、明确操作，满足 5.1.2(i)）：
     「你的健康数据将发送到你配置的服务器，并可能被你接入的第三方 AI Agent 读取。」
     必须主动点「同意并继续」，不能默认勾选
  ④ 选择数据类型（默认全选 MVP 类型）
  ⑤ 请求 HealthKit 授权 → 开始首次回填
主界面（Tab）
  · 概览：最近 7 天睡眠时长 / 阶段、静息心率、HRV、步数（Swift Charts）
  · 同步：每种类型的最后同步时间、本地待上传状态、「立即同步」按钮、最近错误
  · 设置：服务器配置、数据类型、回填范围、断开连接、删除服务器数据、隐私政策、MCP 配置说明
```

概览页的数据**直接从本地 HealthKit 读取**，不依赖服务器。这样 App 本身有独立的使用价值（满足 4.2），审核员也能看到真实内容。

### 5.3 同步引擎（核心，必须可靠）

- **注册时机**：在 `application(_:didFinishLaunchingWithOptions:)` 中通过 `UIApplicationDelegateAdaptor` **同步注册**每个已选类型的 `HKObserverQuery`，再调用 `enableBackgroundDelivery`。后台唤醒会重新走启动流程，在 SwiftUI 视图里注册会漏掉回调。
- **增量查询**：用 `HKAnchoredObjectQueryDescriptor`，每种类型单独保存一个 anchor（`NSKeyedArchiver` 存进 `UserDefaults`，或放在 App Group 文件里）。
- **提交语义**：一轮查询的所有批次都上传成功后，才持久化新的 anchor。中途失败则丢弃，下次从旧 anchor 重放；服务端按 uuid 幂等，重放是安全的。
- **completionHandler**：Observer 回调里的 `completionHandler` 无论成功失败都必须调用，否则 iOS 会降低唤醒频率。
- **后台时间**：后台执行时间很短，单次同步要控制在约 25 秒内。超时就本轮结束，等下次唤醒继续。可以用 `beginBackgroundTask` 申请额外时间。
- **并发**：同一类型同一时间只允许一个同步任务（用 actor 串行化）。
- **首次回填**：默认 30 天，可在设置中改为 7 / 30 / 90 / 365 天或全部。大量历史数据按批次分轮上传。
- **Keychain**：Token 的可访问性设为 `kSecAttrAccessibleAfterFirstUnlock`，否则锁屏状态下的后台任务读不到 Token。
- **锁屏 / 无网**：查询或上传失败时记录到同步状态，不推进 anchor，等待下次触发。
- **补充触发**：App 进入前台时，对所有类型执行一次同步。`BGAppRefreshTask` 作为后续增强，本期不做。
- **断开连接**：停止所有 Observer，调用 `disableAllBackgroundDelivery`，清除 anchor 和 Keychain。

### 5.4 样本转换
- 数量型样本：按 4.3 的单位调用 `doubleValue(for:)`。
- 分类型样本：取 `value`。
- `source` 取 `sourceRevision.source.name`，`device` 取 `sourceRevision.productType`。
- `tz_min`：优先解析 `metadata[HKMetadataKeyTimeZone]`，没有时用 `TimeZone.current.secondsFromGMT(for: startDate)/60`。

## 6. App Store 审核与合规

| 条款 | 要求 | 落实位置 |
|---|---|---|
| 5.1.3 | 健康数据只用于健康管理；不得用于广告或数据挖掘；不得存入 iCloud | 架构本身满足；App 不集成任何分析 / 广告 SDK |
| 5.1.2(i) | 与第三方（含第三方 AI）分享个人数据前，须明确告知并取得同意 | 引导流程第 ③ 步的独立同意页；设置中可撤回同意 |
| 5.1.1 | 隐私政策 URL；只申请必要权限 | `docs/privacy.md` 发布为网页；按用户所选类型申请授权 |
| 2.5.1 | 界面中明确展示 HealthKit 功能 | 概览页、同步页 |
| 4.2 | 最低功能要求 | 概览图表 + 同步状态 + 管理功能 |
| 2.1 | 审核员要能完整测试 | 部署一个审核专用的演示 Worker；在 Review Notes 中提供 URL、Token、操作步骤和预期结果；审核结束后清空数据并轮换 Token |

- **App 隐私标签**：数据只发往用户自己部署的服务器，开发者无法访问。按 Apple 对「收集」的定义，倾向申报「不收集数据」。**提交前须再对照 Apple 官方定义确认**，隐私政策中写明数据流向。
- **中国大陆商店**：大陆上架需要 App 备案。首发可先排除中国大陆区，同时并行办理备案。
- **开源许可**：待定（建议 MIT），Worker 和 App 同仓开源，有助于建立用户信任。

## 7. 里程碑与验收标准

| 里程碑 | 内容 | 验收标准 |
|---|---|---|
| **M0 服务端** | 数据表、4 个 HTTP 接口、4 个 MCP 工具、鉴权、测试 | vitest 覆盖：鉴权（401 / 双 Token 隔离）、ingest 幂等（重复上传不重复）、删除、批量上限、未知类型 400、aggregate 按本地日期分桶（含跨时区样本）、sleep_summary 去重（构造 iPhone + Watch 重叠数据）。用 MCP Inspector 实际调通 4 个工具 |
| **M1 自用版 App** | 同步引擎 + 极简设置页（URL / Token / 立即同步 / 状态） | 真机：首次回填 30 天成功；锁屏一夜后，早上解锁 15 分钟内睡眠数据可经 MCP 查到；在健康 App 中删除一条样本后，服务端同步删除；断网后上传失败、恢复网络后补齐且不重复；强杀 App 后重新打开能恢复 |
| **M2 上架就绪** | 完整引导与同意页、概览页、设置全部功能、隐私政策、Deploy 按钮、README | 新 Cloudflare 账号仅凭 README 即可完成部署并接通 Agent；断开连接后不再上传；删除服务器数据生效；全部界面支持深色模式、动态字体、VoiceOver 基础可用 |
| **M3 提交审核** | 审核演示 Worker、Review Notes、截图、隐私标签 | 通过审核 |

## 8. 风险

| 风险 | 影响 | 应对 |
|---|---|---|
| 后台唤醒频率低于预期 | 数据延迟大 | 进入前台时主动同步；工具返回数据新鲜度，让 Agent 知道数据是否过时 |
| 4.2 / 5.1.2 被拒 | 上架延期 | 概览页提供独立价值；同意页文案提前对照条款打磨 |
| 睡眠数据多来源重复 | 汇总结果偏大 | 4.5 节的去重规则 + 测试用例 |
| 用户部署门槛 | 用户流失 | Deploy 按钮 + 图文 README；以后再考虑方案 B |
| 心率样本量大 | D1 体积、查询变慢 | 单用户量级预估：每年约 10–50 万行，D1 可以承受；如有需要，后续对超过 1 年的心率做降采样 |
| Bearer Token 不被某些 MCP 客户端支持 | 部分 Agent 接不上 | 后续加 OAuth（`workers-oauth-provider`） |

## 9. 请审查者重点核对（共 9 项）

1. `agents/mcp` 的 `createMcpHandler` 当前 API 与用法，以及无状态模式能否满足需求。
2. Deploy to Cloudflare 按钮对 D1 自动创建、迁移执行、secret 提示的支持现状。
3. 5.1.2(i)（第三方 AI 数据分享）的最新原文，以及同意页设计是否足够。
4. 「不收集数据」的隐私标签申报是否成立。
5. `HKMetadataKeyTimeZone` 在睡眠和心率样本中的实际覆盖情况；覆盖不到时的回退方案是否可接受。
6. 睡眠「晚」的归属规则（18:00 分界）以及去重规则是否合理。
7. 后台同步约 25 秒的时间预算，以及 anchor 提交语义有没有丢数据的漏洞。
8. 双 Token 设计是否必要，或者是否还不够（例如需要加 Token 轮换流程）。
9. 方案 A 的数据模型和鉴权结构，是否真的能按 1.1 节的路径平滑演进到方案 B，有没有现在不改、以后改代价很大的地方。

## 10. 待定事项

- 上架名称与 Bundle ID。
- 开源许可。
- 隐私政策的托管位置（GitHub Pages / Cloudflare Pages）。
- 是否首发即上中国大陆区（取决于备案进度）。

### 2026-11-03 Token 初始化补充（用户确认）

客户端可用系统安全随机数生成两枚独立 256 位 Token，作为 Keychain 草稿保存。用户将同值配置到 Cloudflare Secrets 并部署后，测试成功才启用连接。已有部署可导入原 Token。Agent 页面支持保存、验证和快捷复制 MCP 只读 Token 及客户端配置，预览不暴露凭据，写入 Token 不进入 Agent 配置。App 不保存 Cloudflare 管理凭据，不自动更改远程 Secrets。

### 首次安装流程修正（2026-11-03 用户确认）

首次开通以 README 的 Cloudflare 官方部署向导为起点，自动配置 D1、迁移和两个长期 Token，仅要求一个连接口令。部署后的最小连接页生成 256 位、5 分钟有效的配对票据，App 扫码/粘贴并确认目标服务器，通过 HTTPS 领取凭据。D1 仅保存票据和领取标识的摘要，并以事务保证单设备领取；相同客户端可重试丢失响应。首次领取完成后，原连接口令不能再生成配对票据。换机需要部署所有者在 Cloudflare 更换连接口令。

这不是服务端健康数据面板；连接页不展示健康数据，连接也不代表共享同意。默认 App 文案和配置项保持克制，手动凭据配置转入高级入口。
