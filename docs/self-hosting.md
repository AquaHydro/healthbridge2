# 自部署、升级与恢复

## 推荐：README 一键部署

Cloudflare 会从公开仓库创建你自己的副本，配置专属 Worker 和 D1，并运行根目录的部署脚本。只需要设置 `CONNECT_PASSWORD`，建议用密码管理器生成至少 16 字符的口令。

部署脚本自动生成缺失的 `INGEST_TOKEN` 和 `MCP_TOKEN`，写入 Worker Secrets，不打印值、不写进 Git。后续部署保留现有 Token，先应用新增 D1 迁移，再更新 Worker。

部署后打开 Worker 根地址，输入连接口令，即可生成短时链接或二维码。它只包含服务器地址和一次性连接票据，不包含上传或 MCP Token。App 在你确认服务器后，通过 HTTPS 换取两种凭据，分开存入 Keychain；接入服务器不等于同意上传健康数据。

按 [Cloudflare 官方部署按钮规范](https://developers.cloudflare.com/workers/platform/deploy-buttons/)，仓库根目录提供 `wrangler.jsonc`、`.dev.vars.example`、依赖锁文件和 `deploy` 脚本。不要把 `server/` 单独作为模板源目录，它依赖根工作区及锁文件。

## 手动部署

```sh
npm ci
npx wrangler login
npx wrangler whoami
npx wrangler d1 create healthbridge-db
```

核对账号，将新数据库 ID 写入根 `wrangler.jsonc` 的 `d1_databases[0].database_id`。不要填写其他项目的 ID。需要不同 Worker 名称时同时调整根配置的 `name`。

```sh
npx wrangler secret put CONNECT_PASSWORD
npm run deploy
```

`secret put` 首次可能询问是否创建同名 Worker，先核对名称。也可由安全的部署环境注入 `CONNECT_PASSWORD`，部署脚本会在缺失时写入。不要把口令放在命令参数、日志或 URL 中。

如部署权限不足，检查 Workers Scripts 写权限及 D1 写权限。插件与 Wrangler 登录独立；不要尝试从插件导出凭据。

## 本地开发

```sh
npm ci
npx wrangler d1 migrations apply DB --local
npm run dev
```

开发服务器在本地使用明确标记的合成凭据，不能用于公网部署。`npm run dev` 明确使用 `--local`，与生产资源分离。所有健康数据 API 需要上传 Token，MCP 需要独立只读 Token；仅连接页面和受口令/票据保护的配对端点允许进入首次连接流程。

`npm run check` 运行格式、类型、Workers 运行时测试和本地打包，不部署远程资源。

## 配对安全

- 连接口令仅用于证明部署所有权；不是上传或 MCP 凭据。
- 每个口令在第一次成功领取后关闭配对，重新生成未领取链接会替换之前的链接。
- 票据使用 256 位安全随机数，仅保存 SHA-256 摘要，5 分钟过期。
- 原子事务保证只有一个客户端领取。App 将独立的随机领取标识存入 Keychain，同一设备可在有效期内重试丢失的响应。
- 配对尝试按来源及全局限速。浏览器跨站请求拒绝，页面禁用缓存、外部脚本、框架嵌入和 Referer。
- 链接将票据放在自定义 URL 的 fragment 中，长期 Token 不进入二维码、URL 或页面。
- 不采用“第一个匿名访问者认领服务器”的方式。
- 清空健康数据不会重新开放配对。

## 升级、换机与凭据轮换

更新代码后执行 `npm ci && npm run deploy`，迁移只新增，不修改已应用记录。脚本检查现有 Secret 名称，绝不在普通升级时重新生成 Token。

换机时，在 Cloudflare 更新 `CONNECT_PASSWORD`，重新访问连接页并完成配对。修改连接口令不影响正在同步的设备或现有 Agent。

如果旧设备丢失，更新连接口令并不足以撤销它：还应轮换 `INGEST_TOKEN`；需要撤销旧 Agent 时轮换 `MCP_TOKEN`。重新配对会取得当前凭据。旧版 App 可继续通过“手动连接”使用原 Token。

撤回共享只停止新上传，服务端既有数据仍可被持有只读 Token 的 Agent 查询。删除数据为逻辑删除，Cloudflare 历史恢复与备份保留遵循其服务政策。

## 部署验收

使用安全环境注入 `HEALTHBRIDGE_URL`、`INGEST_TOKEN` 和 `MCP_TOKEN`，运行 `node scripts/verify-live.mjs`，验证真实 HTTPS、幂等、MCP 和合成数据清理。不要把真实健康样本写进测试文件。

`verify-pairing-live.mjs` 仅用于专属测试部署：需要测试配置路径，并从本机 Keychain 读取测试连接口令；它会验证领取、重放防护、再次部署和旧凭据仍可使用，不适合直接对已使用的生产配对口令运行。
