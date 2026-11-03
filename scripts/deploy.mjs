import { randomBytes } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { resolve, dirname } from 'node:path';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const config =
  process.env.HEALTHBRIDGE_DEPLOY_CONFIG || resolve(root, 'wrangler.jsonc');
const bin = resolve(root, 'node_modules/wrangler/bin/wrangler.js');
function run(args, { input, allowMissing = false } = {}) {
  const r = spawnSync(process.execPath, [bin, ...args, '--config', config], {
    cwd: root,
    encoding: 'utf8',
    input,
    env: { ...process.env, CI: 'true', WRANGLER_SEND_METRICS: 'false' },
    maxBuffer: 8 * 1024 * 1024,
  });
  if (r.status !== 0) {
    if (
      allowMissing &&
      /10007|worker.*not found|does not exist/i.test(
        (r.stderr || '') + (r.stdout || ''),
      )
    )
      return null;
    // Never relay raw CLI errors from commands that received secret input.
    if (input)
      throw new Error('保存部署凭据失败，请检查 Cloudflare 权限。凭据未输出。');
    process.stderr.write(r.stderr || '');
    process.stderr.write(r.stdout || '');
    throw new Error('部署步骤失败，未继续。');
  }
  return r.stdout;
}
const list = run(['secret', 'list', '--format', 'json'], {
  allowMissing: true,
});
const existing = list === null ? [] : JSON.parse(list.slice(list.indexOf('[')));
const names = new Set(existing.map((s) => s.name));
const secrets = {};
for (const name of ['INGEST_TOKEN', 'MCP_TOKEN'])
  if (!names.has(name)) secrets[name] = randomBytes(32).toString('hex');
if (!names.has('CONNECT_PASSWORD')) {
  const password = process.env.CONNECT_PASSWORD;
  if (!password || password.length < 16 || password.startsWith('synthetic-'))
    throw new Error(
      '请在 Cloudflare 部署向导设置至少 16 字符的 CONNECT_PASSWORD。',
    );
  secrets.CONNECT_PASSWORD = password;
}
if (Object.keys(secrets).length) {
  run(['secret', 'bulk'], { input: JSON.stringify(secrets) });
  console.log('部署凭据已安全配置。已有 Token 保持不变。');
}
// Deploy Buttons provisions D1 and rewrites its ID before this command runs.
process.stdout.write(
  run(['d1', 'migrations', 'apply', 'DB', '--remote']) || '',
);
process.stdout.write(run(['deploy']) || '');
console.log('部署完成后，打开 Worker 地址并输入连接口令，在 iPhone 中继续。');
