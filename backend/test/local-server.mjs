// Runs the API handlers on localhost for tests. State lives in TODODO_LOCAL_FILE (or Postgres if DATABASE_URL is set).
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

process.env.APP_TOKEN ??= 'test-app';
process.env.MCP_TOKEN ??= 'test-mcp';
process.env.TODODO_LOCAL_FILE ??= '/tmp/tododo-test-state.json';
const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const sync = (await import(path.join(root, 'api/sync.js'))).default;
const mcp = (await import(path.join(root, 'api/mcp/[token].js'))).default;

http.createServer(async (req, res) => {
  let raw = '';
  for await (const chunk of req) raw += chunk;
  let body;
  try { body = raw ? JSON.parse(raw) : {}; } catch { body = null; }
  const url = new URL(req.url, 'http://localhost');
  const shim = {
    setHeader: (k, v) => res.setHeader(k, v),
    status(code) { res.statusCode = code; return this; },
    json(obj) { res.setHeader('content-type', 'application/json'); res.end(JSON.stringify(obj)); },
    end: () => res.end(),
  };
  const request = { method: req.method, headers: req.headers, body, query: {} };
  try {
    if (url.pathname === '/api/sync') return await sync(request, shim);
    const m = url.pathname.match(/^\/api\/mcp\/(.+)$/);
    if (m) { request.query.token = m[1]; return await mcp(request, shim); }
    res.statusCode = 404; res.end('not found');
  } catch (e) {
    res.statusCode = 500; res.end(String(e?.stack || e));
  }
}).listen(Number(process.env.PORT || 8787), '127.0.0.1', () => console.log('listening'));
