// POST /api/sync  { epoch, cursor, changes:[{id,kind,data,updatedAt,deleted}] }
// -> { epoch, cursor, changes:[...] }   Last-write-wins per record by updatedAt.
import { mutate, setRecord } from '../lib/store.js';
import { tokenOk } from '../lib/auth.js';

const KINDS = new Set(['group', 'list', 'task', 'step']);

export default async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).json({ error: 'POST only' });
  const bearer = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  if (!tokenOk(bearer, process.env.APP_TOKEN)) return res.status(401).json({ error: 'unauthorized' });

  const body = typeof req.body === 'string' ? JSON.parse(req.body || '{}') : req.body || {};
  const incoming = Array.isArray(body.changes) ? body.changes : [];

  const out = await mutate((state) => {
    const cursor = body.epoch === state.epoch ? Number(body.cursor) || 0 : 0;
    const mine = new Set();
    const rejected = new Set();
    for (const c of incoming) {
      if (!c || typeof c.id !== 'string' || !KINDS.has(c.kind)) continue;
      const cur = state.records[c.id];
      const ts = Number(c.updatedAt) || 0;
      mine.add(c.id);
      if (cur && cur.updatedAt > ts) { mine.delete(c.id); rejected.add(c.id); continue; } // server copy is newer -> send it back
      if (cur && cur.updatedAt === ts && cur.deleted === !!c.deleted) continue; // already have it
      setRecord(state, c.id, c.kind, c.data || {}, !!c.deleted, ts);
    }
    const changes = Object.values(state.records)
      .filter((r) => rejected.has(r.id) || (r.seq > cursor && !mine.has(r.id)))
      .map(({ seq, ...r }) => r);
    return { epoch: state.epoch, cursor: state.seq, changes };
  });
  res.setHeader('Cache-Control', 'no-store');
  return res.status(200).json(out);
}
