// POST /api/sync  { epoch, cursor, changes:[{id,kind,data,ft,updatedAt,deleted}] }
// -> { epoch, cursor, now, changes:[...] }
// Records merge per field (see lib/store.js), so two devices editing the same task don't clobber each other.
import { mutate, setRecord, mergeRecords, sameContent } from '../lib/store.js';
import { tokenOk } from '../lib/auth.js';

const KINDS = new Set(['group', 'list', 'task', 'step']);

export default async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).json({ error: 'POST only' });
  const bearer = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  if (!tokenOk(bearer, process.env.APP_TOKEN)) return res.status(401).json({ error: 'unauthorized' });

  const body = typeof req.body === 'string' ? JSON.parse(req.body || '{}') : req.body || {};
  const incoming = (Array.isArray(body.changes) ? body.changes : [])
    .filter((c) => c && typeof c.id === 'string' && KINDS.has(c.kind));

  const out = await mutate((state) => {
    const cursor = body.epoch === state.epoch ? Number(body.cursor) || 0 : 0;
    const settled = new Set(); // sent by this client and stored exactly as sent -> no need to send back
    const echo = new Set();    // merged into something different -> client must take the merged version
    for (const c of incoming) {
      const inc = { id: c.id, kind: c.kind, data: c.data || {}, ft: c.ft, updatedAt: Number(c.updatedAt) || 0, deleted: !!c.deleted };
      const cur = state.records[c.id];
      if (!cur) {
        const stored = setRecord(state, inc.id, inc.kind, inc.data, inc.deleted, inc.updatedAt, inc.ft || {});
        // The server may have filled in missing times: then the device needs the stored version back.
        if (sameContent(stored, inc)) settled.add(c.id); else echo.add(c.id);
        continue;
      }
      const m = mergeRecords(cur, inc);
      let stored = cur;
      if (!sameContent(m, cur) || m.updatedAt !== cur.updatedAt) {
        stored = setRecord(state, cur.id, cur.kind, m.data, m.deleted, m.updatedAt, m.ft);
      }
      if (sameContent(stored, inc)) settled.add(c.id); else echo.add(c.id);
    }
    const changes = Object.values(state.records)
      .filter((r) => echo.has(r.id) || (r.seq > cursor && !settled.has(r.id)))
      .map(({ seq, ...r }) => r);
    return { epoch: state.epoch, cursor: state.seq, now: Date.now(), changes };
  }, { epoch: body.epoch, cursor: body.cursor, ids: incoming.map((c) => c.id) });

  res.setHeader('Cache-Control', 'no-store');
  return res.status(200).json(out);
}
