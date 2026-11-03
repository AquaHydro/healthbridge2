# D1 迁移

`0001_init.sql` 创建样本和同步状态表，只包含结构，无真实数据。

在 `server` 目录执行：

```sh
npx wrangler d1 migrations apply DB --local
npx wrangler d1 migrations apply DB --remote
```

先核对账号及 `DB` 绑定。已应用的迁移不可修改，后续变更增加新的序号文件。正常发布使用 `npm run deploy`，先迁移再部署。

`0003_hourly.sql` 增加步数和心率小时统计及替换范围。不会删除旧原始样本；MCP 聚合在已替换范围内只使用小时统计，避免重复计算。原始样本查询不展开小时统计。

上传仍使用 `/v1/ingest`、`schema_version: 1`，可选字段：

- `hourly`: 每批最多 1000 条 `{type,start_ms,end_ms,tz_min,sum,count,min,max}`，type 仅 `steps` 或 `heart_rate`。UTC 整小时，end=start+3600000。心率按 count 加权；步数使用 HealthKit 累计值，count=1、min=max=sum。
- `hourly_ranges`: 每批最多 1000 条 `{type,start_ms,end_ms}`，边界为 UTC 整小时，结束时间不包含。每个小时必须完整位于同类型的替换范围内。范围内未提交的旧小时会删除，因此空数组可表达删空和重算。

范围替换、小时写入、原始样本更新和同步状态在同一 D1 事务中完成，失败整体回滚。成功响应包含 `hourly` 和 `hourly_ranges` 数量，客户端核对后才能推进本地检查点；旧版本服务端会拒绝新增字段。客户端需拆分大窗口，并在所有批次成功后推进检查点。统计仅包含合成测试数据，不记录上传内容。

`aggregate` 对命中小时统计的非整小时查询边界，以及非整小时 UTC 偏移（例如 UTC+5:30）明确返回错误，因为小时统计不能恢复局部小时或精确本地桶。客户端必须为每个桶保存该时刻的时区偏移；夏令时重复小时由偏移区分。同步状态 `count` 表示有效存储记录数（原始样本或小时桶），`hourly_count` 单列小时桶数，不代表健康测量次数。

`/v1/ping` 和 `/v1/status` 返回 `hourly_schema_version: 1` 供客户端检测协议能力。小时字段 `coverage_start_ms` 可选，默认 `start_ms`，必须位于桶内。共享或服务器删除起点落在小时中间时，客户端只查询并上传该起点之后的数据，并记录真实覆盖起点；MCP 对命中此类不完整桶的聚合明确返回错误，不推算起点之前的数据或把首桶标为完整。
