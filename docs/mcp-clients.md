# 连接个人 AI Agent

推荐在 App 的“设置 → 连接 AI Agent”选择客户端并复制配置。自动配对后，无需再导入 MCP Token。配置包含只读凭据，请仅粘贴到个人私有配置，不要提交到 Git。

## Codex

可使用 App 提供的静态 `http_headers` 配置，也可由密码管理器向客户端进程提供环境变量：

```toml
[mcp_servers.healthbridge]
url = "https://你的服务.workers.dev/mcp"
bearer_token_env_var = "HEALTHBRIDGE_MCP_TOKEN"
```

桌面客户端不一定继承终端环境，请确认实际执行 MCP 的进程可以访问变量。参考 [官方 MCP 配置](https://learn.chatgpt.com/docs/extend/mcp)。

## Claude Code

```json
{
  "mcpServers": {
    "healthbridge": {
      "type": "http",
      "url": "https://你的服务.workers.dev/mcp",
      "headers": { "Authorization": "Bearer ${HEALTHBRIDGE_MCP_TOKEN}" }
    }
  }
}
```

也可复制 App 生成的完整 JSON，合并到个人配置，保留其他服务器条目。参考 [官方 MCP 文档](https://code.claude.com/docs/en/mcp)。

## 查询工具与边界

| 工具              | 用途                                                                |
| ----------------- | ------------------------------------------------------------------- |
| `get_sync_status` | 回答前检查数据新鲜度、各类型计数和上传时间                          |
| `query_samples`   | 按 `[from,to)` 查询已存储的原始样本，最多 2000 条，支持 cursor 分页 |
| `aggregate`       | 按样本本地小时/日期及偏移统计 avg/min/max/sum/count                 |
| `sleep_summary`   | 按 18:00 分夜，单来源/设备优先阶段记录，合并重叠区间                |

时间接受带时区的 ISO 8601 或 `YYYY-MM-DD`。纯日期按 `tz` 分钟偏移解释；省略时使用最近样本偏移。睡眠结束日期不包含。新上传的心率和步数按小时汇总，使用 `aggregate` 查询，无法通过 `query_samples` 还原明细。小时数据查询边界切开小时，或记录时区偏移并非整小时时，`aggregate` 会返回错误，避免误报局部时段统计。旧版上传的步数原始来源求和可能重复；新小时步数使用 HealthKit 统计。

本项目使用 Streamable HTTP + Bearer Token，不含 MCP OAuth。仅支持 OAuth 的连接器不能直接使用；Claude Desktop 等客户端是否支持自定义请求头，应以其当前版本能力为准。
