/** Generated secrets are intentionally absent from the Deploy Button's input form.
 * Validate these dynamically supplied bindings without declaring a parallel Env type. */
export function runtimeTokens(env: Env) {
  const ingest: unknown = Reflect.get(env, 'INGEST_TOKEN');
  const mcp: unknown = Reflect.get(env, 'MCP_TOKEN');
  return typeof ingest === 'string' &&
    ingest.length > 0 &&
    typeof mcp === 'string' &&
    mcp.length > 0
    ? { ingest, mcp }
    : null;
}
