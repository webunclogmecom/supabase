/* derm_restore_locked_not_required.js
 *
 * Companion to migration 2026-07-03_derm_required_manual_lock.sql.
 *
 * Restores every HUMAN "DERM not required" decision that the nightly re-derive cron
 * (rederive_visits_derm_required) had re-promoted to REQUIRED, and LOCKS it so it can
 * never be re-promoted again (sets derm_required=false, derm_required_locked=true).
 *
 * "Human decision" = the most recent DERM-Tracker (app_source='derm-tracker') UPDATE that
 * actually changed visits.derm_required, per visit. Only decisions of `false` are restored
 * (the "not required" button is the only human writer — last_true has always been 0).
 *
 * IDEMPOTENT: re-running after the fix restores/locks 0 rows.
 *
 *   node scripts/probes/derm_restore_locked_not_required.js            # audit only (read-only)
 *   node scripts/probes/derm_restore_locked_not_required.js --execute  # apply restore+lock
 */
const https = require('https');
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const PAT = process.env.SUPABASE_PAT, P = process.env.SUPABASE_PROJECT_ID;
const EXECUTE = process.argv.includes('--execute');
function pg(q){return new Promise((res,rej)=>{const b=JSON.stringify({query:q});const r=https.request({hostname:'api.supabase.com',path:`/v1/projects/${P}/database/query`,method:'POST',headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json','Content-Length':Buffer.byteLength(b)}},x=>{let d='';x.on('data',c=>d+=c);x.on('end',()=>{let j;try{j=JSON.parse(d);}catch(e){return rej(new Error('pg parse: '+d.slice(0,200)));} if(!Array.isArray(j))return rej(new Error('pg error: '+JSON.stringify(j).slice(0,200))); res(j);});});r.on('error',rej);r.write(b);r.end();});}

const LH = `WITH lh AS (
  SELECT DISTINCT ON ((record_pk->>'id')::bigint)
    (record_pk->>'id')::bigint visit_id, (new_row->>'derm_required')::boolean decided
  FROM audit.logs
  WHERE table_name='visits' AND app_source='derm-tracker'
    AND (new_row ? 'derm_required')
    AND (new_row->>'derm_required') IS DISTINCT FROM (old_row->>'derm_required')
  ORDER BY (record_pk->>'id')::bigint, changed_at DESC)`;

(async () => {
  const audit = await pg(`${LH}
    SELECT
      count(*) FILTER (WHERE decided=false) human_not_required,
      count(*) FILTER (WHERE decided=false AND v.derm_required IS TRUE AND v.deleted_at IS NULL) flipped_to_required_live,
      count(*) FILTER (WHERE decided=false AND NOT v.derm_required_locked) not_yet_locked
    FROM lh JOIN public.visits v ON v.id=lh.visit_id`);
  const a = audit[0];
  console.log(`Human "not required" decisions: ${a.human_not_required} | flipped back to REQUIRED (live): ${a.flipped_to_required_live} | not yet locked: ${a.not_yet_locked}`);

  if (!EXECUTE) {
    console.log('\n(read-only — pass --execute to restore + lock)');
    console.log(`\n--- audit complete --- {"probe":"derm_restore_locked_not_required","flipped_live":${a.flipped_to_required_live},"not_yet_locked":${a.not_yet_locked}}`);
    return;
  }
  const res = await pg(`${LH}
    UPDATE public.visits v SET derm_required=false, derm_required_locked=true
    FROM lh WHERE lh.visit_id=v.id AND lh.decided=false
      AND (v.derm_required IS DISTINCT FROM false OR v.derm_required_locked IS DISTINCT FROM true)
    RETURNING v.id`);
  console.log(`RESTORED+LOCKED ${res.length} visits.`);
  console.log(`\n--- audit complete --- {"probe":"derm_restore_locked_not_required","restored_locked":${res.length}}`);
})().catch(e => { console.error('FATAL', e.message); process.exit(1); });
