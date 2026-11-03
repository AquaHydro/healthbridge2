# HealthBridge

把 iPhone 健康数据同步到你自己的 Cloudflare，让个人 AI Agent 通过只读 MCP 查询。

## 一键部署

[![Deploy to Cloudflare](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/AquaHydro/healthbridge)

1. 登录 Cloudflare，设置一个 **连接口令**（`CONNECT_PASSWORD`，至少 16 个字符）。
2. 等待部署完成，打开生成的 Worker 地址。
3. 输入连接口令，在 iPhone 上点“在 App 中继续”，或用 HealthBridge 扫码。

Worker、D1、迁移和两枚独立 Token 由部署流程配置。App 自动保存连接，随后由你选择共享范围并完成系统健康授权，无需手工填写 Token。

连接码 5 分钟有效，仅允许一台设备领取。成功连接后，原连接口令停止配对。需要换机时，在自己的 Cloudflare 中更换连接口令，再生成新连接码。

## 在 App 中使用

- **概览**：直接查看本机健康数据。
- **同步**：查看进度和触发原因，必要时立即同步；在设置中选择期望的自动同步频率。
- **设置 → 连接 AI Agent**：选择客户端，复制只读配置。

可以仅在本机使用，也可以随时撤回共享。撤回停止后续上传，已上传的数据需另行删除。心率和步数在 iPhone 上按小时汇总后上传，服务器无法还原具体测量时间；其他所选类型仍按样本同步。自动同步频率是期望值，后台更新由 iOS 调度，锁屏期间可能等待解锁后补齐。打开 App 本身不会主动同步。

## 安装与开发

需要 Node.js 24 LTS。iOS 使用 Xcode，最低支持 iOS 17；HealthKit 后台行为需要真机验证。

```sh
npm ci
npm run check
npm run dev
```

本地开发仅使用内置的合成凭据；首次运行前执行 `npx wrangler d1 migrations apply DB --local`。打开 `ios/HealthBridge.xcodeproj`，选择自己的开发团队，在 iPhone 上运行。

## 文档

- [自部署、升级与恢复](docs/self-hosting.md)
- [iOS 构建与签名](ios/README.md)
- [MCP 客户端配置](docs/mcp-clients.md)
- [隐私说明](docs/privacy.md)
- [验收记录与限制](docs/verification/MVP.md)
- [开发方案](HealthBridge-开发方案.md) · [页面流程](docs/design/流程与页面.md)

仅提供单用户自部署模式，无托管账号和服务端健康数据面板。一键部署仍需要你在 Cloudflare 官方向导中登录、授权并确认资源，项目不会保存 Cloudflare 管理凭据。
