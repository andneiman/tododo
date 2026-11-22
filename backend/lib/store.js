// Storage for the single-user state.
//   Postgres (DATABASE_URL / POSTGRES_URL) is the primary store.
//   Without it, falls back to one private Vercel Blob guarded by ETag.
// A "state" is { epoch, seq, records: { [id]: record } },
//   record = { id, kind, data, ft, updatedAt, deleted, seq }.
// `ft` holds a timestamp per data field, so edits to different fields of one
// record made on different devices merge instead of overwriting each other.
import { randomUUID } from 'node:crypto';
import fs from 'node:fs';

const BLOB_PATH = 'tododo/state.json';
const LOCAL = process.env.TODODO_LOCAL_FILE; // tests only
const PG_URL = process.env.DATABASE_URL || process.env.POSTGRES_URL || process.env.POSTGRES_PRISMA_URL;
const BACKUP_KEEP_DAYS = 90;

const fresh = () => ({ epoch: randomUUID(), seq: 0, records: {} });
export const backend = PG_URL ? 'postgres' : LOCAL ? 'file' : 'blob';

// ---------- record helpers (shared by sync and tools) ----------

// Tasks and steps always carry createdAt, completedAt while completed, and deletedAt while deleted,
// whoever wrote them (an app, an older app version, or Claude). Times are ms since 1970.
function stampTimes(kind, data, deleted, updatedAt, prev) {
  if (kind !== 'task' && kind !== 'step') return [];
  const added = [];
  if (!data.createdAt) {
    data.createdAt = prev?.data?.createdAt || updatedAt;
    added.push('createdAt');
  }
  if (data.completed) {
    if (!data.completedAt) {
      data.completedAt = (prev?.data?.completed && prev.data.completedAt) || updatedAt;
      added.push('completedAt');
    }
  } else if (data.completedAt) {
    delete data.completedAt;
    added.push('completedAt');
  }
  if (deleted) {
    if (!data.deletedAt) {
      data.deletedAt = (prev?.deleted && prev.data?.deletedAt) || updatedAt;
      added.push('deletedAt');
    }
  } else if (data.deletedAt) {
    delete data.deletedAt;
    added.push('deletedAt');
  }
  return added;
}

export function setRecord(state, id, kind, data, deleted = false, updatedAt = Date.now(), ft) {
  const prev = state.records[id];
  data = { ...data };
  const stamped = stampTimes(kind, data, deleted, updatedAt, prev);
  if (ft) {
    ft = { ...ft };
    for (const f of stamped) ft[f] = Math.max(ft[f] || 0, updatedAt);
  }
  if (!ft) {
    // Stamp only the fields that actually changed.
    ft = { ...(prev?.ft || {}) };
    const before = prev?.data || {};
    for (const k of new Set([...Object.keys(before), ...Object.keys(data)])) {
      if (JSON.stringify(before[k]) !== JSON.stringify(data[k])) ft[k] = updatedAt;
    }
  }
  state.seq += 1;
  state.records[id] = { id, kind, data, ft, updatedAt, deleted, seq: state.seq };
  return state.records[id];
}

const fieldTime = (r, f) => r.ft?.[f] ?? (r.ft ? 0 : r.updatedAt);

// Field-level last-write-wins. Returns the merged { data, ft, updatedAt, deleted }.
export function mergeRecords(cur, inc) {
  const data = {};
  const ft = {};
  const fields = new Set([
    ...Object.keys(cur.data || {}), ...Object.keys(inc.data || {}),
    ...Object.keys(cur.ft || {}), ...Object.keys(inc.ft || {}),
  ]);
  for (const f of fields) {
    const tc = fieldTime(cur, f);
    const ti = fieldTime(inc, f);
    const win = ti > tc ? inc : cur;
    const v = win.data?.[f];
    if (v !== undefined && v !== null) data[f] = v;
    ft[f] = Math.max(tc, ti);
  }
  const newer = inc.updatedAt > cur.updatedAt ? inc : cur;
  return { data, ft, updatedAt: newer.updatedAt, deleted: !!newer.deleted };
}

export const sameContent = (a, b) =>
  !!a.deleted === !!b.deleted && canon(a.data) === canon(b.data);
const canon = (o) => JSON.stringify(Object.keys(o || {}).sort().map((k) => [k, o[k]]));

// ---------- Postgres ----------

let pool;
let ready;
async function pg() {
  if (!pool) {
    const { default: pgm } = await import('pg');
    pool = new pgm.Pool({ connectionString: PG_URL, max: 2, idleTimeoutMillis: 10_000 });
    pool.on('error', () => {});
  }
  if (!ready) {
    ready = (async () => {
      await pool.query(`
        create table if not exists records (
          id text primary key,
          kind text not null,
          data jsonb not null,
          ft jsonb not null default '{}',
          updated_at double precision not null,
          deleted boolean not null default false,
          seq bigint not null
        );
        create index if not exists records_seq on records (seq);
        create table if not exists meta (key text primary key, value jsonb not null);
        create table if not exists backups (
          day text primary key,
          taken_at timestamptz not null default now(),
          records_count int not null,
          state jsonb not null
        );
      `);
      await importFromBlobOnce();
    })().catch((e) => { ready = null; throw e; });
  }
  await ready;
  return pool;
}

const rowToRecord = (r) => ({
  id: r.id, kind: r.kind, data: r.data, ft: r.ft || {}, updatedAt: Number(r.updated_at), deleted: r.deleted, seq: Number(r.seq),
});

async function upsert(client, recs) {
  for (let i = 0; i < recs.length; i += 200) {
    const chunk = recs.slice(i, i + 200);
    const vals = [];
    const ph = chunk.map((r, j) => {
      vals.push(r.id, r.kind, JSON.stringify(r.data || {}), JSON.stringify(r.ft || {}), r.updatedAt, !!r.deleted, r.seq);
      const b = j * 7;
      return `($${b + 1},$${b + 2},$${b + 3}::jsonb,$${b + 4}::jsonb,$${b + 5},$${b + 6},$${b + 7})`;
    });
    await client.query(
      `insert into records (id, kind, data, ft, updated_at, deleted, seq) values ${ph.join(',')}
       on conflict (id) do update set kind = excluded.kind, data = excluded.data, ft = excluded.ft,
         updated_at = excluded.updated_at, deleted = excluded.deleted, seq = excluded.seq`,
      vals,
    );
  }
}

// One-time move of the state that lived in Vercel Blob (keeps epoch and seq, so devices carry on).
async function importFromBlobOnce() {
  const client = await pool.connect();
  try {
    await client.query('begin');
    await client.query('select pg_advisory_xact_lock(7001)');
    const has = await client.query(`select 1 from meta where key = 'epoch'`);
    if (!has.rowCount) {
      let state = fresh();
      try {
        const old = await blobLoad();
        if (old.etag) state = old.state;
      } catch {}
      await upsert(client, Object.values(state.records).map((r) => ({ ft: {}, ...r })));
      await client.query(`insert into meta (key, value) values ('epoch', $1::jsonb), ('seq', $2::jsonb)`,
        [JSON.stringify(state.epoch), JSON.stringify(state.seq)]);
    }
    await client.query('commit');
  } catch (e) {
    await client.query('rollback').catch(() => {});
    throw e;
  } finally {
    client.release();
  }
}

async function pgMutate(fn, subset) {
  const db = await pg();
  const client = await db.connect();
  try {
    await client.query('begin');
    await client.query('select pg_advisory_xact_lock(7001)');
    const meta = Object.fromEntries((await client.query('select key, value from meta')).rows.map((r) => [r.key, r.value]));
    const state = { epoch: meta.epoch, seq: Number(meta.seq) || 0, records: {}, lastBackupDay: meta.lastBackupDay };
    const cursor = subset ? (subset.epoch === state.epoch ? Number(subset.cursor) || 0 : 0) : null;
    const rows = subset
      ? await client.query('select * from records where seq > $1 or id = any($2::text[])', [cursor, subset.ids || []])
      : await client.query('select * from records');
    for (const r of rows.rows) state.records[r.id] = rowToRecord(r);
    const before = state.seq;

    const result = await fn(state);

    if (state.seq !== before) {
      await upsert(client, Object.values(state.records).filter((r) => r.seq > before));
      await client.query(`update meta set value = $1::jsonb where key = 'seq'`, [JSON.stringify(state.seq)]);
      // First write of the day: keep a snapshot of everything as it was before this write.
      const day = new Date().toISOString().slice(0, 10);
      if (state.lastBackupDay !== day) await pgBackup(client, day, before);
    }
    await client.query('commit');
    return result;
  } catch (e) {
    await client.query('rollback').catch(() => {});
    throw e;
  } finally {
    client.release();
  }
}

// Daily copy of the whole table, taken with the first write of each day.
async function pgBackup(client, day, seqBefore) {
  const all = (await client.query('select * from records')).rows.map(rowToRecord);
  const epoch = (await client.query(`select value from meta where key = 'epoch'`)).rows[0]?.value;
  const state = { epoch, seq: Math.max(seqBefore, ...all.map((r) => r.seq), 0), records: Object.fromEntries(all.map((r) => [r.id, r])) };
  await client.query(
    `insert into backups (day, records_count, state) values ($1, $2, $3::jsonb)
     on conflict (day) do nothing`,
    [day, all.filter((r) => !r.deleted).length, JSON.stringify(state)],
  );
  await client.query(`delete from backups where taken_at < now() - ($1 || ' days')::interval`, [String(BACKUP_KEEP_DAYS)]);
  await client.query(
    `insert into meta (key, value) values ('lastBackupDay', $1::jsonb)
     on conflict (key) do update set value = excluded.value`,
    [JSON.stringify(day)],
  );
  // Second copy outside the database. Best effort.
  if (process.env.BLOB_READ_WRITE_TOKEN) {
    try {
      const { put } = await import('@vercel/blob');
      await put(`tododo/backups/${day}.json`, JSON.stringify(state), {
        access: 'private', allowOverwrite: true, addRandomSuffix: false, contentType: 'application/json',
      });
    } catch {}
  }
}

export async function listBackups() {
  if (backend !== 'postgres') return [];
  const db = await pg();
  const r = await db.query('select day, taken_at, records_count from backups order by day desc');
  return r.rows.map((x) => ({ day: x.day, taken_at: x.taken_at, tasks_and_lists: x.records_count }));
}

export async function getBackup(day) {
  if (backend !== 'postgres') return null;
  const db = await pg();
  const r = await db.query('select state from backups where day = $1', [day]);
  return r.rows[0]?.state ?? null;
}

// ---------- Blob / file fallback ----------

async function blobLoad() {
  if (LOCAL) {
    if (!fs.existsSync(LOCAL)) return { state: fresh(), etag: null };
    return { state: JSON.parse(fs.readFileSync(LOCAL, 'utf8')), etag: 'local' };
  }
  if (!process.env.BLOB_READ_WRITE_TOKEN) return { state: fresh(), etag: null };
  const { get } = await import('@vercel/blob');
  const r = await get(BLOB_PATH, { access: 'private', useCache: false });
  if (!r || r.statusCode !== 200 || !r.stream) return { state: fresh(), etag: null };
  const text = await new Response(r.stream).text();
  return { state: JSON.parse(text), etag: r.blob.etag };
}

async function blobSave(state, etag) {
  if (LOCAL) return fs.writeFileSync(LOCAL, JSON.stringify(state));
  const { put } = await import('@vercel/blob');
  await put(BLOB_PATH, JSON.stringify(state), {
    access: 'private', allowOverwrite: true, addRandomSuffix: false, contentType: 'application/json',
    ...(etag ? { ifMatch: etag } : {}),
  });
}

async function blobMutate(fn) {
  let lastErr;
  for (let attempt = 0; attempt < 6; attempt++) {
    const { state, etag } = await blobLoad();
    const before = state.seq;
    const result = await fn(state);
    if (state.seq === before && etag) return result;
    try {
      await blobSave(state, etag);
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

// fn(state) mutates state in place (through setRecord) and returns a result.
// subset = { epoch, cursor, ids }: load only what a sync round needs instead of everything.
export function mutate(fn, subset) {
  return backend === 'postgres' ? pgMutate(fn, subset) : blobMutate(fn);
}
