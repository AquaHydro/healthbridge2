import { cloudflareTest } from '@cloudflare/vitest-plugin';
import { defineConfig } from 'vitest/config';

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: '../wrangler.jsonc' },
      miniflare: {
        bindings: {
          INGEST_TOKEN: 'synthetic-ingest-test-only',
          CONNECT_PASSWORD: 'synthetic-connection-password-test-only',
          MCP_TOKEN: 'synthetic-mcp-test-only',
        },
      },
    }),
  ],
});
