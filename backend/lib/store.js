// Single-user state in one private Vercel Blob, guarded by ETag (optimistic concurrency).
// state = { epoch, seq, records: { [id]: { id, kind, data, updatedAt, deleted, seq } } }
import { randomUUID } from 'node:crypto';
import fs from 'node:fs';

const PATH = 'tododo/state.json';
const LOCAL = process.env.TODODO_LOCAL_FILE; // for local tests only

const fresh = () => ({ epoch: randomUUID(), seq: 0, records: {} });

async function load() {
  if (LOCAL) {
    if (!fs.existsSync(LOCAL)) return { state: fresh(), etag: null };
    return { state: JSON.parse(fs.readFileSync(LOCAL, 'utf8')), etag: 'local' };
  }
  const { get } = await import('@vercel/blob');
  const r = await get(PATH, { access: 'private', useCache: false });
  if (!r || r.statusCode !== 200 || !r.stream) return { state: fresh(), etag: null };
  const text = await new Response(r.stream).text();
  return { state: JSON.parse(text), etag: r.blob.etag };
}

async function save(state, etag) {
  if (LOCAL) return fs.writeFileSync(LOCAL, JSON.stringify(state));
  const { put } = await import('@vercel/blob');
  await put(PATH, JSON.stringify(state), {
    access: 'private',
    allowOverwrite: true,
    addRandomSuffix: false,
    contentType: 'application/json',
    ...(etag ? { ifMatch: etag } : {}),
  });
}

export async function read() {
  return (await load()).state;
}

// fn(state) mutates state in place and returns a result. Saved only if seq changed.
export async function mutate(fn) {
  let lastErr;
  for (let attempt = 0; attempt < 6; attempt++) {
    const { state, etag } = await load();
    const before = state.seq;
    const result = await fn(state);
    if (state.seq === before && etag) return result;
    try {
      await save(state, etag);
      return result;
    } catch (e) {
      if (e?.name === 'BlobPreconditionFailedError' || /precondition/i.test(String(e?.message))) {
        lastErr = e;
        await new Promise((r) => setTimeout(r, 40 * (attempt + 1)));
        continue;
      }
      throw e;
    }
  }
  throw lastErr ?? new Error('store conflict');
}

export function setRecord(state, id, kind, data, deleted = false, updatedAt = Date.now()) {
  state.seq += 1;
  state.records[id] = { id, kind, data, updatedAt, deleted, seq: state.seq };
  return state.records[id];
}
