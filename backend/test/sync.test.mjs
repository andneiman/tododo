import fs from 'node:fs';
process.env.APP_TOKEN='a'; process.env.MCP_TOKEN='m';
const sync=(await import('/home/claude/tododo/backend/api/sync.js')).default;
const mcp=(await import('/home/claude/tododo/backend/api/mcp/[token].js')).default;
const {backend}=await import('/home/claude/tododo/backend/lib/store.js');
const call=(h,req)=>new Promise(r=>{const res={setHeader(){},status(c){this.c=c;return this},json(j){r({c:this.c,j})},end(){r({c:this.c})}};h({headers:{},query:{},...req},res)});
const S=async(b)=>{const r=await call(sync,{method:'POST',headers:{authorization:'Bearer a'},body:b}); if(r.c!==200) throw new Error(JSON.stringify(r)); return r.j};
let n=0;const T=async(name,args)=>{const r=await call(mcp,{method:'POST',query:{token:'m'},body:{jsonrpc:'2.0',id:++n,method:'tools/call',params:{name,arguments:args}}});const c=r.j.result.content[0].text;return r.j.result.isError?c:JSON.parse(c)};
const ok=(c,m)=>{console.log(c?'ok  ':'FAIL',m); if(!c) process.exitCode=1};
console.log('backend',backend, process.argv[2]);
if(process.argv[2]==='seed'){ await T('add_tasks',{tasks:[{title:'из блоба',my_day:true}]}); const r=await S({cursor:0,changes:[]}); console.log('seeded',r.cursor,r.epoch); fs.writeFileSync('/tmp/epoch',r.epoch); process.exit(0)}
const INBOX='00000000-0000-0000-0000-000000000001';
let r=await S({cursor:0,changes:[]});
ok(r.changes.length===1 && r.changes[0].data.title==='из блоба' && r.epoch===fs.readFileSync('/tmp/epoch','utf8'),'imported blob state, epoch kept');
ok(typeof r.now==='number','server time returned');
const ep=r.epoch; let A=r.cursor, B=r.cursor; const t=Date.now();
// phone creates task
r=await S({epoch:ep,cursor:A,changes:[{id:'x1',kind:'task',data:{listId:INBOX,title:'Задача',position:5},ft:{listId:t,title:t,position:t},updatedAt:t,deleted:false}]}); A=r.cursor;
ok(r.changes.length===0,'push not echoed');
r=await S({epoch:ep,cursor:B,changes:[]}); B=r.cursor; ok(r.changes.length===1&&r.changes[0].id==='x1','mac pulls it');
// offline: phone renames (t+10), mac stars + completes (t+20), mac syncs first
r=await S({epoch:ep,cursor:B,changes:[{id:'x1',kind:'task',data:{listId:INBOX,title:'Задача',position:5,important:true,completed:true,completedAt:t+20},ft:{listId:t,title:t,position:t,important:t+20,completed:t+20,completedAt:t+20},updatedAt:t+20,deleted:false}]}); B=r.cursor;
r=await S({epoch:ep,cursor:A,changes:[{id:'x1',kind:'task',data:{listId:INBOX,title:'Задача (переименована)',position:5},ft:{listId:t,title:t+10,position:t},updatedAt:t+10,deleted:false}]}); A=r.cursor;
const m=r.changes.find(c=>c.id==='x1');
ok(m&&m.data.title==='Задача (переименована)'&&m.data.important===true&&m.data.completed===true,'field merge: rename + star + done all survive, merged echoed to phone');
r=await S({epoch:ep,cursor:B,changes:[]}); B=r.cursor; ok(r.changes[0]?.data.title==='Задача (переименована)','mac gets merged');
// un-set field wins when newer
r=await S({epoch:ep,cursor:A,changes:[{id:'x1',kind:'task',data:{listId:INBOX,title:'Задача (переименована)',position:5,completed:true,completedAt:t+20},ft:{...m.ft,important:t+30},updatedAt:t+30,deleted:false}]}); A=r.cursor;
r=await S({epoch:ep,cursor:B,changes:[]}); B=r.cursor; ok(r.changes[0]&&r.changes[0].data.important===undefined,'clearing a field propagates');
// Claude edit vs stale device edit of another field
await T('update_task',{id:'x1',completed:false});
r=await S({epoch:ep,cursor:A,changes:[]}); A=r.cursor; ok(r.changes[0].data.completed===undefined,'claude reopen reaches phone');
// delete on phone, then list_deleted/undelete
r=await S({epoch:ep,cursor:A,changes:[{...r.changes[0],deleted:true,updatedAt:r.changes[0].updatedAt+50}]}); A=r.cursor;
let d=await T('recover',{action:'list_deleted'}); ok(d.deleted.some(x=>x.id==='x1'),'deleted task listed');
d=await T('recover',{action:'undelete',ids:['x1']}); ok(d.restored.length===1,'undelete');
r=await S({epoch:ep,cursor:A,changes:[]}); A=r.cursor; ok(r.changes.some(c=>c.id==='x1'&&!c.deleted),'undeleted task comes back to phone');
// backups
d=await T('recover',{action:'list_backups'}); ok(d.backups.length===1,'daily backup exists: '+JSON.stringify(d.backups[0]));
const L=await T('manage_list',{action:'create',name:'Работа'}); await T('add_tasks',{tasks:[{title:'в работе',list:'Работа',steps:['s1']}]});
// fake: move today's backup to "yesterday" after taking a new one that includes the list
const pg=(await import('/home/claude/tododo/backend/node_modules/pg/lib/index.js')).default; const c=new pg.Client(process.env.DATABASE_URL); await c.connect();
await c.query("delete from backups; delete from meta where key='lastBackupDay'"); await T('add_tasks',{tasks:[{title:'триггер бэкапа'}]});
await T('manage_list',{action:'delete',list:'Работа'});
ok((await T('get_overview',{})).lists.length===1,'list deleted');
const day=(await T('recover',{action:'list_backups'})).backups[0].day;
d=await T('recover',{action:'restore_backup',day}); ok(d.brought_back===3,'restore_backup brings back list+task+step: '+JSON.stringify(d));
ok((await T('list_tasks',{list:'Работа'})).tasks[0]?.steps?.length===1,'restored list has task with step');
// concurrency: 20 parallel pushes + mcp calls
const t2=Date.now(); await Promise.all([...Array(20)].map((_,i)=> i%2? S({epoch:ep,cursor:0,changes:[{id:'c'+i,kind:'task',data:{listId:INBOX,title:'c'+i,position:i},ft:{title:t2},updatedAt:t2,deleted:false}]}) : T('add_tasks',{tasks:[{title:'m'+i}]})));
r=await S({epoch:ep,cursor:0,changes:[]}); const seqs=(await c.query('select seq from records')).rows.map(x=>+x.seq);
ok(new Set(seqs).size===seqs.length && Math.max(...seqs)===r.cursor,'concurrent writes: unique seqs, cursor = max');
ok(r.changes.filter(x=>/^[cm]\d+$/.test(x.data.title)).length===20,'all 20 concurrent items stored');
await c.end(); process.exit(process.exitCode||0);
