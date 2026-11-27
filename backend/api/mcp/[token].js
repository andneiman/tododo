// Minimal stateless MCP server (Streamable HTTP, JSON responses). URL: /api/mcp/<MCP_TOKEN>
import { mutate } from '../../lib/store.js';
import { tokenOk } from '../../lib/auth.js';
import { tools } from '../../lib/tools.js';

// Read-only tools: ChatGPT runs these without asking for confirmation.
const READ_ONLY = new Set(['get_overview', 'list_tasks', 'search_tasks', 'task_history']);
const VERSIONS = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'];
const INSTRUCTIONS =
  'Personal to-do app "Tods" (Microsoft To Do style). Lists hold tasks; tasks can have steps, an "important" flag and a "My Day" flag. ' +
  'My Day does not reset overnight: tasks stay until completed or removed. Section dividers (e.g. "To Do", "Think About") are special items that visually group the tasks below them. ' +
  'There are no due dates or reminders. Changes sync to the user\'s devices within seconds.';

async function rpc(msg) {
  const { id, method, params } = msg;
  const ok = (result) => ({ jsonrpc: '2.0', id, result });
  const err = (code, message) => ({ jsonrpc: '2.0', id, error: { code, message } });
  if (id === undefined || id === null) return null; // notification
  switch (method) {
    case 'initialize':
      return ok({
        protocolVersion: VERSIONS.includes(params?.protocolVersion) ? params.protocolVersion : VERSIONS[1],
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: 'tods', title: 'Tods', version: '1.0.0' },
        instructions: INSTRUCTIONS,
      });
    case 'ping':
      return ok({});
    case 'tools/list':
      return ok({ tools: tools.map(({ name, description, inputSchema }) => ({
        name, description, inputSchema,
        annotations: READ_ONLY.has(name)
          ? { readOnlyHint: true, openWorldHint: false }
          : { readOnlyHint: false, destructiveHint: name === 'delete_tasks', openWorldHint: false },
      })) });
    case 'tools/call': {
      const tool = tools.find((t) => t.name === params?.name);
      if (!tool) return err(-32602, `Unknown tool: ${params?.name}`);
      try {
        const result = await mutate((state) => tool.run(state, params.arguments || {}));
        return ok({ content: [{ type: 'text', text: JSON.stringify(result) }] });
      } catch (e) {
        return ok({ content: [{ type: 'text', text: `Error: ${e.message}` }], isError: true });
      }
    }
    case 'resources/list': return ok({ resources: [] });
    case 'prompts/list': return ok({ prompts: [] });
    default:
      return err(-32601, `Method not found: ${method}`);
  }
}

export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  if (!tokenOk(req.query.token, process.env.MCP_TOKEN)) return res.status(404).json({ error: 'not found' });
  if (req.method !== 'POST') { res.setHeader('Allow', 'POST'); return res.status(405).json({ error: 'POST only' }); }
  let body = req.body;
  if (typeof body === 'string') { try { body = JSON.parse(body); } catch { body = null; } }
  if (!body) return res.status(400).json({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } });
  if (Array.isArray(body)) {
    const out = (await Promise.all(body.map(rpc))).filter(Boolean);
    return out.length ? res.status(200).json(out) : res.status(202).end();
  }
  const out = await rpc(body);
  return out ? res.status(200).json(out) : res.status(202).end();
}
