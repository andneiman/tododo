// Domain logic behind the MCP tools. Operates on the shared state document.
import { randomUUID } from 'node:crypto';
import { setRecord, listBackups, getBackup, backend } from './store.js';

export const INBOX = '00000000-0000-0000-0000-000000000001';
const INBOX_NAME = 'Tasks';

const live = (state, kind) => Object.values(state.records).filter((r) => r.kind === kind && !r.deleted);
const norm = (s) => String(s ?? '').trim().toLowerCase();
const byPos = (key) => (a, b) => (a.data[key] ?? a.data.position ?? 0) - (b.data[key] ?? b.data.position ?? 0);
const fail = (msg) => { throw new Error(msg); };

function update(state, rec, patch) {
  const data = { ...rec.data, ...patch };
  for (const k of Object.keys(data)) if (data[k] === null || data[k] === undefined) delete data[k];
  return setRecord(state, rec.id, rec.kind, data, false, Math.max(Date.now(), rec.updatedAt + 1));
}
function remove(state, rec) {
  return setRecord(state, rec.id, rec.kind, rec.data, true, Math.max(Date.now(), rec.updatedAt + 1));
}

function listName(state, id) {
  if (id === INBOX) return INBOX_NAME;
  const l = state.records[id];
  return l && !l.deleted ? l.data.name : INBOX_NAME;
}
function resolveList(state, ref) {
  if (ref === undefined || ref === null || ref === '') return INBOX;
  const n = norm(ref);
  if (ref === INBOX || ['inbox', 'tasks', 'задачи'].includes(n)) return INBOX;
  const lists = live(state, 'list');
  const hit = lists.find((l) => l.id === ref) || lists.find((l) => norm(l.data.name) === n);
  if (!hit) fail(`List "${ref}" not found. Available: ${[INBOX_NAME, ...lists.map((l) => l.data.name)].join(', ')}`);
  return hit.id;
}
function getTask(state, id) {
  const t = state.records[id];
  if (!t || t.deleted || t.kind !== 'task') fail(`Task ${id} not found`);
  return t;
}
function stepsOf(state, taskId) {
  return live(state, 'step').filter((s) => s.data.taskId === taskId).sort(byPos('position'));
}
const iso = (ms) => (ms ? new Date(ms).toISOString() : undefined);
function times(r) {
  return {
    created_at: iso(r.data.createdAt),
    ...(r.data.completedAt ? { completed_at: iso(r.data.completedAt) } : {}),
    ...(r.deleted && r.data.deletedAt ? { deleted_at: iso(r.data.deletedAt) } : {}),
  };
}
function view(state, t) {
  if (t.data.isSection) return { id: t.id, section: t.data.title, list: listName(state, t.data.listId), ...(t.data.myDay ? { my_day: true } : {}) };
  const steps = stepsOf(state, t.id).map((s) => ({ id: s.id, title: s.data.title, completed: !!s.data.completed, ...(s.data.important ? { starred: true } : {}) }));
  return {
    id: t.id,
    title: t.data.title,
    list: listName(state, t.data.listId),
    completed: !!t.data.completed,
    important: !!t.data.important,
    my_day: !!t.data.myDay,
    ...times(t),
    ...(t.data.note ? { note: t.data.note } : {}),
    ...(steps.length ? { steps } : {}),
  };
}
// Position for a new item: end of the ordering, or end of a named section's block.
function slot(items, key, sectionTitle) {
  const sorted = [...items].sort(byPos(key));
  const pos = (r) => r.data[key] ?? r.data.position ?? 0;
  if (sectionTitle) {
    const i = sorted.findIndex((r) => r.data.isSection && norm(r.data.title) === norm(sectionTitle));
    if (i < 0) fail(`Section "${sectionTitle}" not found. Sections: ${sorted.filter((r) => r.data.isSection).map((r) => r.data.title).join(', ') || 'none'}`);
    let j = i + 1;
    while (j < sorted.length && !sorted[j].data.isSection) j++;
    const prev = pos(sorted[j - 1]);
    return j < sorted.length ? (prev + pos(sorted[j])) / 2 : prev + 1;
  }
  return sorted.length ? pos(sorted[sorted.length - 1]) + 1 : 1;
}
// Position above everything (new tasks go to the top, like in the apps).
function top(items, key) {
  const pos = (r) => r.data[key] ?? r.data.position ?? 0;
  return items.length ? Math.min(...items.map(pos)) - 1 : 1;
}
const COLORS = ['black', 'gray', 'red', 'orange', 'green', 'teal', 'blue', 'indigo', 'purple', 'pink', 'brown'];
const parseTitle = (raw) => {
  const t = String(raw ?? '').trim();
  const m = t.match(/^#+\s*(.+)$/);
  return m ? { title: m[1].trim(), isSection: true } : { title: t, isSection: false };
};

export const tools = [
  {
    name: 'get_overview',
    description: 'Overview of the to-do app: smart lists (My Day, Important, default "Tasks" inbox), user lists with their groups, and open-task counts. Call first to learn list names.',
    inputSchema: { type: 'object', properties: {} },
    run(state) {
      const tasks = live(state, 'task').filter((t) => !t.data.isSection);
      const open = tasks.filter((t) => !t.data.completed);
      const groups = Object.fromEntries(live(state, 'group').map((g) => [g.id, g.data.name]));
      return {
        my_day_open: open.filter((t) => t.data.myDay).length,
        important_open: open.filter((t) => t.data.important).length,
        lists: [
          { id: INBOX, name: INBOX_NAME, open: open.filter((t) => t.data.listId === INBOX).length },
          ...live(state, 'list').sort(byPos('position')).map((l) => ({
            id: l.id, name: l.data.name,
            ...(l.data.groupId && groups[l.data.groupId] ? { group: groups[l.data.groupId] } : {}),
            open: open.filter((t) => t.data.listId === l.id).length,
          })),
        ],
      };
    },
  },
  {
    name: 'list_tasks',
    description: 'List tasks in display order. view: "my_day" (My Day — tasks stay there until completed), "important", "all", or omit view and pass list (name or id; default inbox "Tasks"). Items with a "section" field are visual dividers (e.g. "To Do", "Think About"); tasks below a divider belong to it.',
    inputSchema: {
      type: 'object',
      properties: {
        view: { type: 'string', enum: ['my_day', 'important', 'all'] },
        list: { type: 'string', description: 'List name or id' },
        include_completed: { type: 'boolean', description: 'Default false' },
      },
    },
    run(state, a) {
      let items = live(state, 'task');
      let key = 'position';
      if (a.view === 'my_day') { items = items.filter((t) => t.data.myDay); key = 'myDayPosition'; }
      else if (a.view === 'important') items = items.filter((t) => t.data.important && !t.data.isSection);
      else if (a.view !== 'all') { const id = resolveList(state, a.list); items = items.filter((t) => t.data.listId === id && !(t.data.isSection && t.data.myDay)); }
      if (!a.include_completed) items = items.filter((t) => !t.data.completed);
      items.sort(a.view === 'all' || a.view === 'important'
        ? (x, y) => listName(state, x.data.listId).localeCompare(listName(state, y.data.listId)) || byPos('position')(x, y)
        : byPos(key));
      return { count: items.filter((t) => !t.data.isSection).length, tasks: items.map((t) => view(state, t)) };
    },
  },
  {
    name: 'search_tasks',
    description: 'Find tasks whose title or steps contain the query (case-insensitive).',
    inputSchema: { type: 'object', properties: { query: { type: 'string' }, include_completed: { type: 'boolean' } }, required: ['query'] },
    run(state, a) {
      const q = norm(a.query);
      const hits = live(state, 'task').filter((t) => !t.data.isSection && (a.include_completed || !t.data.completed) &&
        (norm(t.data.title).includes(q) || stepsOf(state, t.id).some((s) => norm(s.data.title).includes(q))));
      return { count: hits.length, tasks: hits.map((t) => view(state, t)) };
    },
  },
  {
    name: 'add_tasks',
    description: 'Create one or more tasks. Each goes to the top of its list (or to the end of the given section). Set my_day to also put it in My Day. A title starting with "#" creates a section divider instead of a task.',
    inputSchema: {
      type: 'object',
      properties: {
        tasks: {
          type: 'array', minItems: 1,
          items: {
            type: 'object',
            properties: {
              title: { type: 'string' },
              list: { type: 'string', description: 'List name or id; default inbox "Tasks"' },
              section: { type: 'string', description: 'Title of an existing section divider to place the task under' },
              my_day: { type: 'boolean' },
              important: { type: 'boolean' },
              steps: { type: 'array', items: { type: 'string' } },
              note: { type: 'string', description: 'Free-form note' },
            },
            required: ['title'],
          },
        },
      },
      required: ['tasks'],
    },
    run(state, a) {
      const created = [];
      for (const t of a.tasks || []) {
        const { title, isSection } = parseTitle(t.title);
        if (!title) fail('Empty title');
        const listId = resolveList(state, t.list);
        const all = live(state, 'task');
        const inList = all.filter((x) => x.data.listId === listId && !(x.data.isSection && x.data.myDay)); // My Day dividers are My Day's own
        const myDay = all.filter((x) => x.data.myDay);
        const secInList = t.section && inList.some((x) => x.data.isSection && norm(x.data.title) === norm(t.section));
        const secInDay = t.section && myDay.some((x) => x.data.isSection && norm(x.data.title) === norm(t.section));
        if (t.section && !secInList && !(t.my_day && secInDay)) slot(inList, 'position', t.section); // throws a helpful error
        const now = Date.now();
        const data = {
          listId, title, position: secInList ? slot(inList, 'position', t.section) : top(inList, 'position'), createdAt: now,
          ...(isSection ? { isSection: true } : {}),
          ...(t.important && !isSection ? { important: true } : {}),
          ...(t.note && !isSection ? { note: String(t.note) } : {}),
          ...(t.my_day ? { myDay: true, myDayPosition: secInDay ? slot(myDay, 'myDayPosition', t.section) : top(myDay, 'myDayPosition') } : {}),
        };
        const rec = setRecord(state, randomUUID(), 'task', data);
        if (!isSection) (t.steps || []).forEach((s, i) => setRecord(state, randomUUID(), 'step', { taskId: rec.id, title: String(s), position: i + 1 }));
        created.push(view(state, rec));
      }
      return { created };
    },
  },
  {
    name: 'update_task',
    description: 'Change a task: rename, set its note, complete/reopen, toggle important or My Day, move to another list, move under a section, or set a section divider\'s color. Only provided fields change.',
    inputSchema: {
      type: 'object',
      properties: {
        id: { type: 'string' },
        title: { type: 'string' },
        completed: { type: 'boolean' },
        important: { type: 'boolean' },
        my_day: { type: 'boolean' },
        list: { type: 'string', description: 'Move to this list (name or id)' },
        color: { type: 'string', enum: COLORS, description: 'Text color of a section divider (black is the default)' },
        note: { type: 'string', description: 'Free-form note of the task ("" clears it)' },
        section: { type: 'string', description: 'Move to the end of this section (in the task list, and in My Day if the section is there)' },
      },
      required: ['id'],
    },
    run(state, a) {
      const t = getTask(state, a.id);
      const patch = {};
      if (a.title !== undefined) patch.title = String(a.title).trim() || fail('Empty title');
      if (a.completed !== undefined) {
        patch.completed = a.completed || null; patch.completedAt = a.completed ? Date.now() : null;
        // Reopened tasks come back at the top, like everything that (re)appears in a list.
        if (!a.completed && t.data.completed) {
          const rest = live(state, 'task').filter((x) => x.id !== t.id);
          patch.position = top(rest.filter((x) => x.data.listId === t.data.listId), 'position');
          if (t.data.myDay) patch.myDayPosition = top(rest.filter((x) => x.data.myDay), 'myDayPosition');
        }
      }
      if (a.important !== undefined) {
        patch.important = a.important || null;
        // Starring lifts the task to the very top of its list and of My Day, like in the apps.
        if (a.important && !t.data.important && !t.data.completed && a.section === undefined) {
          const others = live(state, 'task').filter((x) => x.id !== t.id);
          const listId = a.list !== undefined ? resolveList(state, a.list) : t.data.listId;
          patch.position = top(others.filter((x) => x.data.listId === listId), 'position');
          if (t.data.myDay || a.my_day) patch.myDayPosition = top(others.filter((x) => x.data.myDay), 'myDayPosition');
        }
      }
      if (a.note !== undefined) patch.note = String(a.note).trim() ? String(a.note) : null;
      if (a.color !== undefined) {
        if (!COLORS.includes(a.color)) fail(`color must be one of: ${COLORS.join(', ')}`);
        patch.color = a.color === 'black' ? null : a.color;
      }
      const others = live(state, 'task').filter((x) => x.id !== t.id);
      let listId = t.data.listId;
      if (a.list !== undefined) {
        listId = resolveList(state, a.list);
        if (listId !== t.data.listId) { patch.listId = listId; patch.position = top(others.filter((x) => x.data.listId === listId), 'position'); }
      }
      const willBeMyDay = a.my_day !== undefined ? a.my_day : !!t.data.myDay;
      if (a.my_day !== undefined && a.my_day !== !!t.data.myDay) {
        patch.myDay = a.my_day || null;
        patch.myDayPosition = a.my_day ? top(others.filter((x) => x.data.myDay), 'myDayPosition') : null;
        // Added to My Day: it also goes to the top of its own list.
        if (a.my_day && !t.data.completed && !t.data.isSection) patch.position = top(others.filter((x) => x.data.listId === t.data.listId), 'position');
      }
      if (a.section) {
        const inList = others.filter((x) => x.data.listId === listId);
        const day = others.filter((x) => x.data.myDay);
        const has = (arr) => arr.some((x) => x.data.isSection && norm(x.data.title) === norm(a.section));
        if (!has(inList) && !(willBeMyDay && has(day))) slot(inList, 'position', a.section);
        if (has(inList)) patch.position = slot(inList, 'position', a.section);
        if (willBeMyDay && has(day)) patch.myDayPosition = slot(day, 'myDayPosition', a.section);
      }
      return view(state, update(state, t, patch));
    },
  },
  {
    name: 'delete_tasks',
    description: 'Permanently delete tasks (or section dividers) by id, with their steps.',
    inputSchema: { type: 'object', properties: { ids: { type: 'array', items: { type: 'string' }, minItems: 1 } }, required: ['ids'] },
    run(state, a) {
      const deleted = [];
      for (const id of a.ids || []) {
        const t = getTask(state, id);
        stepsOf(state, id).forEach((s) => remove(state, s));
        remove(state, t);
        deleted.push(t.data.title);
      }
      return { deleted };
    },
  },
  {
    name: 'edit_steps',
    description: 'Manage steps (subtasks) of a task: add new ones, and/or update, star or delete existing steps by id. Starred steps are shown right under the task in the list (the user\'s focus for now).',
    inputSchema: {
      type: 'object',
      properties: {
        task_id: { type: 'string' },
        add: { type: 'array', items: { type: 'string' } },
        update: {
          type: 'array',
          items: { type: 'object', properties: { id: { type: 'string' }, title: { type: 'string' }, completed: { type: 'boolean' }, starred: { type: 'boolean', description: 'Show this step right under the task in the list' }, delete: { type: 'boolean' } }, required: ['id'] },
        },
      },
      required: ['task_id'],
    },
    run(state, a) {
      const t = getTask(state, a.task_id);
      for (const u of a.update || []) {
        const s = state.records[u.id];
        if (!s || s.deleted || s.kind !== 'step' || s.data.taskId !== t.id) fail(`Step ${u.id} not found in this task`);
        if (u.delete) { remove(state, s); continue; }
        const patch = {};
        if (u.title !== undefined) patch.title = String(u.title);
        if (u.completed !== undefined) patch.completed = u.completed || null; // completedAt is stamped by the store
        if (u.starred !== undefined) patch.important = u.starred || null;
        update(state, s, patch);
      }
      let pos = stepsOf(state, t.id).reduce((m, s) => Math.max(m, s.data.position ?? 0), 0);
      for (const title of a.add || []) setRecord(state, randomUUID(), 'step', { taskId: t.id, title: String(title), position: ++pos });
      return view(state, t);
    },
  },
  {
    name: 'manage_list',
    description: 'Create, rename, regroup or delete a list. action "create" needs name; "update"/"delete" need list (name or id). group: group name to put the list in (created if missing); empty string removes it from its group. Deleting a list deletes its tasks.',
    inputSchema: {
      type: 'object',
      properties: {
        action: { type: 'string', enum: ['create', 'update', 'delete'] },
        list: { type: 'string' },
        name: { type: 'string' },
        group: { type: 'string' },
      },
      required: ['action'],
    },
    run(state, a) {
      const groupId = () => {
        if (a.group === undefined) return undefined;
        if (!a.group.trim()) return null;
        const g = live(state, 'group').find((x) => norm(x.data.name) === norm(a.group));
        if (g) return g.id;
        return setRecord(state, randomUUID(), 'group', { name: a.group.trim(), position: slot(live(state, 'group'), 'position') }).id;
      };
      if (a.action === 'create') {
        const name = String(a.name ?? '').trim() || fail('name is required');
        if (live(state, 'list').some((l) => norm(l.data.name) === norm(name)) || norm(name) === norm(INBOX_NAME)) fail(`List "${name}" already exists`);
        const g = groupId();
        const rec = setRecord(state, randomUUID(), 'list', { name, position: slot(live(state, 'list'), 'position'), ...(g ? { groupId: g } : {}) });
        return { id: rec.id, name };
      }
      const id = resolveList(state, a.list ?? fail('list is required'));
      if (id === INBOX) fail('The default "Tasks" list cannot be changed or deleted');
      const l = state.records[id];
      if (a.action === 'delete') {
        const tasks = live(state, 'task').filter((t) => t.data.listId === id);
        tasks.forEach((t) => { stepsOf(state, t.id).forEach((s) => remove(state, s)); remove(state, t); });
        remove(state, l);
        return { deleted: l.data.name, tasks_deleted: tasks.length };
      }
      const patch = {};
      if (a.name !== undefined) patch.name = String(a.name).trim() || fail('Empty name');
      const g = groupId();
      if (g !== undefined) patch.groupId = g;
      const rec = update(state, l, patch);
      return { id: rec.id, name: rec.data.name };
    },
  },
  {
    name: 'recover',
    description: 'Safety net. Nothing is ever erased on the server: deleted tasks/lists stay recoverable, and a full snapshot is kept for each day with changes (90 days). action "list_deleted": recently deleted tasks and lists (days, default 30). "undelete": bring back items by ids (a list comes back with its tasks). "list_backups": available daily snapshots. "restore_backup": bring back everything from the snapshot of `day` (YYYY-MM-DD) that has since been deleted; with overwrite=true also revert items changed since then. Items created after the snapshot are never removed.',
    inputSchema: {
      type: 'object',
      properties: {
        action: { type: 'string', enum: ['list_deleted', 'undelete', 'list_backups', 'restore_backup'] },
        days: { type: 'number' },
        ids: { type: 'array', items: { type: 'string' } },
        day: { type: 'string' },
        overwrite: { type: 'boolean' },
      },
      required: ['action'],
    },
    async run(state, a) {
      const all = Object.values(state.records);
      const revive = (r, data = r.data) => {
        const now = Math.max(Date.now(), r.updatedAt + 1);
        const ft = Object.fromEntries([...Object.keys(r.data || {}), ...Object.keys(data)].map((k) => [k, now]));
        return setRecord(state, r.id, r.kind, data, false, now, ft);
      };
      if (a.action === 'list_deleted') {
        const since = Date.now() - (a.days ?? 30) * 86400000;
        const gone = all.filter((r) => r.deleted && r.updatedAt >= since && (r.kind === 'task' || r.kind === 'list'))
          .sort((x, y) => y.updatedAt - x.updatedAt).slice(0, 200);
        return { deleted: gone.map((r) => ({ id: r.id, kind: r.kind, title: r.data.title ?? r.data.name, list: r.kind === 'task' ? listName(state, r.data.listId) : undefined, deleted_at: new Date(r.updatedAt).toISOString() })) };
      }
      if (a.action === 'undelete') {
        const restored = [];
        for (const id of a.ids || []) {
          const r = state.records[id];
          if (!r) fail(`Item ${id} not found`);
          if (!r.deleted) continue;
          revive(r);
          restored.push(r.data.title ?? r.data.name);
          const children = r.kind === 'list' ? all.filter((x) => x.kind === 'task' && x.data.listId === id && x.deleted && x.updatedAt >= r.updatedAt - 5000)
            : r.kind === 'task' ? all.filter((x) => x.kind === 'step' && x.data.taskId === id && x.deleted && x.updatedAt >= r.updatedAt - 5000) : [];
          for (const c of children) {
            revive(c);
            if (c.kind === 'task') all.filter((x) => x.kind === 'step' && x.data.taskId === c.id && x.deleted && x.updatedAt >= c.updatedAt - 5000).forEach((x) => revive(x));
          }
        }
        return { restored };
      }
      if (a.action === 'list_backups') {
        if (backend !== 'postgres') return { backups: [], note: 'Daily snapshots need the Postgres store.' };
        return { backups: await listBackups() };
      }
      if (a.action === 'restore_backup') {
        const snap = await getBackup(String(a.day ?? ''));
        if (!snap) fail(`No backup for "${a.day}". Use action "list_backups".`);
        let undeleted = 0, reverted = 0;
        for (const old of Object.values(snap.records)) {
          if (old.deleted) continue;
          const cur = state.records[old.id];
          if (!cur) { setRecord(state, old.id, old.kind, old.data, false, Date.now()); undeleted++; }
          else if (cur.deleted) { revive(cur, old.data); undeleted++; }
          else if (a.overwrite && JSON.stringify(cur.data) !== JSON.stringify(old.data)) { revive(cur, old.data); reverted++; }
        }
        return { day: a.day, brought_back: undeleted, reverted };
      }
      fail('Unknown action');
    },
  },
  {
    name: 'task_history',
    description: 'Task history for analysis: every task (open, completed and, if asked, deleted) with created_at, completed_at and deleted_at (ISO, UTC), its list, flags and step counts. Filter by a time window on any of those dates. Use it for questions like "what did I finish last week", "how long do tasks stay open", "what did I add in October". Section dividers are left out.',
    inputSchema: {
      type: 'object',
      properties: {
        since: { type: 'string', description: 'ISO date or date-time; keep tasks with the chosen date on or after it' },
        until: { type: 'string', description: 'ISO date or date-time; keep tasks with the chosen date before it' },
        by: { type: 'string', enum: ['created', 'completed', 'deleted'], description: 'Which date since/until apply to (default created)' },
        list: { type: 'string', description: 'Only this list (name or id)' },
        include_deleted: { type: 'boolean', description: 'Also return deleted tasks (default false)' },
        limit: { type: 'number', description: 'Max rows, newest first (default 2000)' },
      },
    },
    run(state, a) {
      const by = a.by || 'created';
      const field = { created: 'createdAt', completed: 'completedAt', deleted: 'deletedAt' }[by] || 'createdAt';
      const since = a.since ? Date.parse(a.since) : -Infinity;
      const until = a.until ? Date.parse(a.until) : Infinity;
      if (Number.isNaN(since) || Number.isNaN(until)) fail('since/until must be ISO dates, e.g. 2026-11-01');
      const listId = a.list !== undefined ? resolveList(state, a.list) : null;
      const steps = {};
      for (const s of Object.values(state.records)) {
        if (s.kind !== 'step' || s.deleted) continue;
        const k = (steps[s.data.taskId] ||= { total: 0, done: 0 });
        k.total++; if (s.data.completed) k.done++;
      }
      const rows = Object.values(state.records)
        .filter((t) => t.kind === 'task' && !t.data.isSection && (a.include_deleted || by === 'deleted' || !t.deleted))
        .filter((t) => !listId || t.data.listId === listId)
        .filter((t) => { const v = t.data[field]; return v ? v >= since && v < until : (since === -Infinity && until === Infinity && by === 'created'); })
        .sort((x, y) => (y.data[field] || 0) - (x.data[field] || 0))
        .slice(0, Math.max(1, Math.min(Number(a.limit) || 2000, 5000)))
        .map((t) => ({
          title: t.data.title,
          list: listName(state, t.data.listId),
          status: t.deleted ? 'deleted' : t.data.completed ? 'completed' : 'open',
          ...times(t),
          ...(t.data.important ? { important: true } : {}),
          ...(t.data.myDay ? { my_day: true } : {}),
          ...(steps[t.id] ? { steps_done: steps[t.id].done, steps_total: steps[t.id].total } : {}),
        }));
      const count = (st) => rows.filter((r) => r.status === st).length;
      return { count: rows.length, open: count('open'), completed: count('completed'), deleted: count('deleted'), tasks: rows };
    },
  },
];
