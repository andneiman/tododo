// GET /api/share/<taskId>?k=<key>  ->  the task as plain text, for an AI agent (ChatGPT, Claude…) to read.
// The key is an HMAC of the task id with the app token, so a link opens exactly one task and nothing else.
// Always live: the agent sees the task as it is now (title, list, steps, note).
import { createHmac } from 'node:crypto';
import { mutate } from '../../lib/store.js';
import { tokenOk } from '../../lib/auth.js';

export const shareKey = (id, secret) => createHmac('sha256', String(secret)).update(String(id)).digest('hex').slice(0, 24);

export default async function handler(req, res) {
  const id = String(req.query.id || '');
  const secret = process.env.APP_TOKEN;
  if (!id || !secret || !tokenOk(String(req.query.k || ''), shareKey(id, secret))) {
    return res.status(404).send('Not found');
  }
  const text = await mutate((state) => {
    const r = state.records;
    const t = r[id];
    if (!t || t.kind !== 'task' || t.deleted) return null;
    const list = t.data.listId && r[t.data.listId] && !r[t.data.listId].deleted ? r[t.data.listId].data.name : 'Tasks';
    const day = (ms) => (ms ? new Date(ms).toISOString().slice(0, 10) : null);
    const steps = Object.values(r)
      .filter((s) => s.kind === 'step' && !s.deleted && s.data.taskId === id)
      .sort((a, b) => (a.data.position || 0) - (b.data.position || 0));
    const lines = [`# ${t.data.title || ''}`, ''];
    lines.push(`List: ${list}`);
    const flags = [t.data.completed ? 'completed' : 'open', t.data.important ? 'important' : null, t.data.myDay ? 'in My Day' : null].filter(Boolean);
    lines.push(`Status: ${flags.join(', ')}`);
    if (day(t.data.createdAt)) lines.push(`Created: ${day(t.data.createdAt)}`);
    if (t.data.completed && day(t.data.completedAt)) lines.push(`Completed: ${day(t.data.completedAt)}`);
    if (steps.length) {
      lines.push('', `## Steps (${steps.filter((s) => s.data.completed).length} of ${steps.length} done)`);
      for (const s of steps) lines.push(`- [${s.data.completed ? 'x' : ' '}] ${s.data.title || ''}`);
    }
    if (t.data.note && t.data.note.trim()) lines.push('', '## Note', t.data.note.trim());
    lines.push('', '---', 'This is a task from my to-do app. Help me think it through and move it forward.');
    return lines.join('\n');
  });
  if (!text) return res.status(404).send('Not found');
  res.setHeader('Content-Type', 'text/plain; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('X-Robots-Tag', 'noindex');
  return res.status(200).send(text);
}
