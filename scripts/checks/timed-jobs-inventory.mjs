// TIMED JOBS INVENTORY
// Every scheduled job in the three runtimes, as one Markdown table (two self-timed jobs are named under it,
// not listed: services/db-backup, a loop that times itself, and the GDO report bot on its developer's Railway):
//   pg_cron   cron.job on Prod, via the Management API. Only the FIRST FUNCTION NAME (plus a lowercase
//             mode word and the edge fn its wrapper calls) is extracted, inside SQL: the command text
//             never leaves the DB, because it can carry headers and keys.
//   Railway   services/timed-jobs/services.json (the file apply.js pushes; the dashboard is not read).
//   GitHub    .github/workflows/*.yml with a `- cron:` line (a retired workflow keeps only its button).
// Read-only. Public repo: the output holds job names and ids, schedules, function, edge fn and script names,
// nothing else.
// Run:  node scripts/checks/timed-jobs-inventory.mjs           (Markdown to stdout)
//       node scripts/checks/timed-jobs-inventory.mjs --write   (also writes docs/reference/scheduled-jobs.md)
import { readFileSync, writeFileSync, readdirSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const OUT = join(ROOT, 'docs', 'reference', 'scheduled-jobs.md');
const WF = join(ROOT, '.github', 'workflows');
const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

// UTC cron -> ET wall clock (EDT = UTC-4, EST = UTC-5). Interval crons do not shift.
function etNote(cron) {
  const f = cron.trim().split(/\s+/);
  if (f.length !== 5) return 'interval, same in ET';
  const [m, h, dom, , dow] = f;
  if (h === '*' && /^\d+(,\d+)*$/.test(m)) return `hourly at ${m.split(',').map(x => ':' + x.padStart(2, '0')).join(', ')}, same in ET`;
  if (h === '*') return 'interval, same in ET';
  if (!/^\d+$/.test(m)) return 'see UTC'; // e.g. */5 9 * * *: a fixed UTC hour, so it does shift
  const step = h.startsWith('*/') ? +h.slice(2) : 0;
  const hours = step ? Array.from({ length: Math.ceil(24 / step) }, (_, i) => i * step) : h.split(',').map(Number);
  if (hours.some(x => !Number.isInteger(x) || x < 0 || x > 23)) return 'see UTC';
  const at = off => hours.map(x => {
    const t = x - off;
    const day = /^\d$/.test(dow) ? DAYS[(+dow + (t < 0 ? 6 : 0)) % 7] + ' ' : '';
    return day + String((t + 24) % 24).padStart(2, '0') + ':' + m.padStart(2, '0');
  }).join(', ');
  let note = `${at(4)} EDT / ${at(5)} EST`;
  if (dom !== '*') note += ` (day-of-month ${dom} is UTC)`;
  if (dow !== '*' && !/^\d$/.test(dow)) note += ` (weekdays ${dow} are UTC)`;
  return note;
}

// Every `- cron:` value in a workflow, quoted or not, trailing comment dropped.
const cronsOf = text => [...text.matchAll(/^\s*-\s*cron:\s*(['"]?)(.+?)\1\s*(?:#.*)?$/gm)].map(x => x[2].trim());
const scriptsOf = text => [...new Set([...text.matchAll(/node\s+(scripts\/[^\s"'`]+)/g)].map(x => x[1]))];

// Positive controls: the parsers must work on known inputs before their output is trusted.
assert.equal(etNote('15 9 * * *'), '05:15 EDT / 04:15 EST');
assert.equal(etNote('0 14 * * 0'), 'Sun 10:00 EDT / Sun 09:00 EST');
assert.equal(etNote('0 2 * * 1'), 'Sun 22:00 EDT / Sun 21:00 EST');
assert.equal(etNote('0 */12 * * *'), '20:00, 08:00 EDT / 19:00, 07:00 EST');
assert.equal(etNote('*/5 * * * *'), 'interval, same in ET');
assert.equal(etNote('17 * * * *'), 'hourly at :17, same in ET');
assert.equal(etNote('15,45 * * * *'), 'hourly at :15, :45, same in ET');
assert.equal(etNote('30 seconds'), 'interval, same in ET');
assert.equal(etNote('*/5 9 * * *'), 'see UTC');
assert.deepEqual(cronsOf("  schedule:\n    # - cron: '1 1 * * *'\n    - cron: '0 */6 * * *'   # note\r\n    - cron: \"30 * * * *\"\n    - cron: 5 4 * * *\n"),
  ['0 */6 * * *', '30 * * * *', '5 4 * * *']);
assert.deepEqual(scriptsOf("run: node scripts/a.js --x\n  node scripts/b/c.js\n  node scripts/a.js"), ['scripts/a.js', 'scripts/b/c.js']);

async function pgCron() {
  const env = Object.fromEntries(readFileSync(join(ROOT, '.env'), 'utf8').split(/\r?\n/)
    .filter(l => /^[A-Z_]+=/.test(l))
    .map(l => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^"|"$/g, '').trim()]));
  if (!env.SUPABASE_PAT || !env.SUPABASE_PROJECT_ID) throw new Error('SUPABASE_PAT / SUPABASE_PROJECT_ID missing from .env');
  // POSIX classes and [(] instead of backslash escapes: immune to string-literal mangling (CLAUDE.md 5).
  // mode = a lowercase word literal right after the FIRST paren (fn_request_jobber_sync('poll')); the class
  // has no digits or capitals, so a key or token (which carries them) cannot match it. edge = the one edge fn
  // the wrapper's own body names (today no cron command posts to an edge fn itself, each calls a SQL wrapper);
  // several = a dispatcher (fn_request_jobber_sync names 6), left out. A wrapper that reaches an edge fn
  // through another function shows none.
  const q = `with j as (select jobid, coalesce(jobname, '(unnamed)') as jobname, schedule, active,
      substring(command from '([[:alpha:]_][[:alnum:]_.]*)[[:space:]]*[(]') as fn,
      substring(command from '^[^(]*[(][[:space:]]*''([a-z_-]{1,30})''') as mode from cron.job)
    select j.jobid, j.jobname, j.schedule, j.active, j.fn, j.mode,
      (select case when count(distinct m[1]) = 1 then min(m[1]) end
         from pg_proc p join pg_namespace n on n.oid = p.pronamespace,
              regexp_matches(p.prosrc, 'functions/v1/([[:alnum:]_-]+)', 'g') m
        where n.nspname || '.' || p.proname = j.fn) as edge
    from j order by 2, 1`;
  const r = await fetch(`https://api.supabase.com/v1/projects/${env.SUPABASE_PROJECT_ID}/database/query`, {
    method: 'POST', headers: { Authorization: `Bearer ${env.SUPABASE_PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: q }) });
  const j = JSON.parse(await r.text());
  if (!Array.isArray(j)) throw new Error(`Management API error (HTTP ${r.status}): ${JSON.stringify(j).slice(0, 200)}`);
  return j.map(x => ({
    runtime: 'pg_cron', name: x.active ? x.jobname : `${x.jobname} (PAUSED)`, cron: x.schedule,
    runs: x.fn ? `\`${x.fn}${x.mode ? `('${x.mode}')` : ''}\`` + (x.edge ? `, edge fn \`${x.edge}\`` : '') : '(no function call found)',
    health: `\`cron.job_run_details\` jobid ${x.jobid}`,
  }));
}

function railway() {
  const cfg = JSON.parse(readFileSync(join(ROOT, 'services', 'timed-jobs', 'services.json'), 'utf8'));
  return Object.entries(cfg.services).sort().map(([name, s]) => {
    const m = s.startCommand.match(/run_logged\.js\s+(\S+)\s+(.+)$/);
    return {
      runtime: 'Railway', name, cron: s.cronSchedule,
      runs: `\`${m ? m[2] : s.startCommand}\``,
      health: m ? `\`public.sync_log\` source \`${m[1]}\`` : 'unknown (not wrapped in run_logged.js)',
    };
  });
}

function github() {
  return readdirSync(WF).filter(f => /\.ya?ml$/.test(f)).sort().flatMap(file => {
    const text = readFileSync(join(WF, file), 'utf8');
    const scripts = scriptsOf(text);
    return cronsOf(text).map(cron => ({
      runtime: 'GitHub', name: `\`${file}\``, cron,
      runs: scripts.length ? scripts.map(s => `\`${s}\``).join(', ') : '(see workflow)',
      health: `Actions history (\`gh run list -w ${file}\`)`,
    }));
  });
}

const groups = { pg_cron: await pgCron(), Railway: railway(), GitHub: github() };
for (const [k, rs] of Object.entries(groups)) if (!rs.length) throw new Error(`${k} returned 0 jobs: suspect the instrument, not the runtime`);
const rows = Object.values(groups).flat();
const paused = groups.pg_cron.filter(r => r.name.endsWith('(PAUSED)')).length;
const stamp = new Date().toLocaleString('sv-SE', { timeZone: 'America/New_York' }).slice(0, 16);

const md = [
  '# Scheduled jobs',
  '',
  `> **Generated, do not edit by hand.** Written by \`node scripts/checks/timed-jobs-inventory.mjs --write\`,`,
  `> generated on ${stamp} ET. Re-run it after any schedule change and commit the result.`,
  '',
  'Every timed job in pg_cron (Prod), the Railway project UnclogMe Timed Jobs (read from',
  '`services/timed-jobs/services.json`; `node services/timed-jobs/apply.js` shows any drift from Railway) and',
  'GitHub Actions. Schedules are shown as stored, in UTC (pg_cron runs on `cron.timezone` GMT). The ET column converts',
  'fixed-time schedules: EDT = UTC-4 (second Sunday of March to first Sunday of November), EST = UTC-5.',
  'pg_cron shows the first function a job calls and, when that wrapper posts to one edge function, its name.',
  'The command text itself is never read out of the database.',
  '`cron.job_run_details` proves the SQL ran, not that the edge function behind it worked. GitHub does not',
  'keep to its cron, so check its history before trusting a GitHub time.',
  '',
  'Not in this table, because they time themselves: the database backup ([services/db-backup](../../services/db-backup/README.md),',
  'Railway project UnclogMe Backups, a loop that copies every 2 hours at HH:17 UTC, even hours; health in `public.sync_log`',
  'source `db_backup` and pg_cron `db-backup-health`), and the GDO report bot, which runs on its developer\'s own Railway',
  'deployment, not ours ([its triggers](gdo-rpa-bot-triggers.md)).',
  '',
  'Background: [timed jobs on Railway](../../services/timed-jobs/README.md), [the move decision log](../audits/2026-10-07_timed_jobs_move.md).',
  '',
  '| runtime | name | schedule (UTC) | ET | what it runs | health source |',
  '|---|---|---|---|---|---|',
  ...rows.map(r => `| ${r.runtime} | ${r.name} | \`${r.cron}\` | ${etNote(r.cron)} | ${r.runs} | ${r.health} |`),
  '',
  `Totals: pg_cron ${groups.pg_cron.length} (${paused} paused), Railway ${groups.Railway.length}, ` +
    `GitHub ${groups.GitHub.length} schedules in ${new Set(groups.GitHub.map(r => r.name)).size} workflows.`,
  '',
].join('\n');

process.stdout.write(md);
if (process.argv.includes('--write')) {
  mkdirSync(dirname(OUT), { recursive: true });
  writeFileSync(OUT, md);
  console.error(`wrote ${OUT}`);
}
