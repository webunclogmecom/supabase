import { readFileSync } from 'node:fs';
const env = Object.fromEntries(readFileSync('.env','utf8').split(/\r?\n/).filter(l=>/^[A-Z_]+=/.test(l))
  .map(l=>[l.slice(0,l.indexOf('=')), l.slice(l.indexOf('=')+1).replace(/^"|"$/g,'').trim()]));
let q = readFileSync(process.argv[2],'utf8');
if (process.argv[3] === 'rehearse') {
  const before = q.length;
  // case-insensitive: migrations in this repo are written with an upper-case COMMIT;
  q = q.replace(/\ncommit;\s*$/i, '\nrollback;\n');
  if (q.length === before) throw new Error('could not swap commit for rollback');
  console.log('REHEARSAL: commit swapped for rollback');
}
const r = await fetch(`https://api.supabase.com/v1/projects/${env.SUPABASE_PROJECT_ID}/database/query`,
  {method:'POST',headers:{Authorization:`Bearer ${env.SUPABASE_PAT}`,'Content-Type':'application/json'},body:JSON.stringify({query:q})});
const t = await r.text();
console.log('HTTP', r.status);
console.log(t.slice(0, 1500));
