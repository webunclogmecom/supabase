import { readFileSync, writeFileSync } from 'fs';
const env=readFileSync('C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase/.env','utf8'); const PAT=env.match(/SUPABASE_PAT=(\S+)/)[1];
async function pg(q){const r=await fetch("https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query",{method:"POST",headers:{Authorization:"Bearer "+PAT,"Content-Type":"application/json"},body:JSON.stringify({query:q})});const j=await r.json();if(!Array.isArray(j))throw new Error(JSON.stringify(j).slice(0,300));return j;}
// the 9 wrong links (visit_id, manifest_id) verified by the audit
const PAIRS=[[1370,300],[1438,408],[1478,923],[1736,961],[1785,988],[3891,101],[3913,52],[3922,1016],[5089,1200]];
const visitIds=[...new Set(PAIRS.map(p=>p[0]))];
const manIds=[...new Set(PAIRS.map(p=>p[1]))];
// 1. BACKUP: all manifest_visits for these visits + the target manifests' full link set
const backup={};
backup.affected_visit_links = await pg(`SELECT mv.visit_id, mv.manifest_id, dm.white_manifest_number, dm.client_id, dm.dump_ticket_date FROM manifest_visits mv JOIN derm_manifests dm ON dm.id=mv.manifest_id WHERE mv.visit_id IN (${visitIds.join(',')}) ORDER BY mv.visit_id, mv.manifest_id`);
backup.pairs_to_delete = PAIRS;
writeFileSync('C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/backups/2026-07-07_manifest_visits_multiwhite_dedup.json', JSON.stringify(backup,null,1));
console.log('backed up '+backup.affected_visit_links.length+' links for '+visitIds.length+' visits');
// 2. DELETE exactly the 9 pairs
const orClauses = PAIRS.map(([v,m])=>`(visit_id=${v} AND manifest_id=${m})`).join(' OR ');
const del = await pg(`DELETE FROM public.manifest_visits WHERE ${orClauses} RETURNING visit_id, manifest_id`);
console.log('deleted '+del.length+' rows:', JSON.stringify(del.map(r=>[r.visit_id,r.manifest_id])));
// 3. VERIFY each visit now has exactly 1 distinct white#
const verify = await pg(`
  SELECT mv.visit_id, count(DISTINCT dm.white_manifest_number) AS n_white, array_agg(DISTINCT dm.white_manifest_number) AS whites
  FROM manifest_visits mv JOIN derm_manifests dm ON dm.id=mv.manifest_id AND dm.deleted_at IS NULL
  WHERE mv.visit_id IN (${visitIds.join(',')})
  GROUP BY mv.visit_id ORDER BY mv.visit_id`);
console.log('post-fix per-visit white# counts:', JSON.stringify(verify));
// 4. FLEET re-check: any visit still with >=2 white#?
const fleet = await pg(`
  WITH x AS (SELECT mv.visit_id, count(DISTINCT dm.white_manifest_number) AS n FROM manifest_visits mv JOIN derm_manifests dm ON dm.id=mv.manifest_id AND dm.deleted_at IS NULL JOIN visits v ON v.id=mv.visit_id AND v.deleted_at IS NULL GROUP BY mv.visit_id)
  SELECT count(*) FILTER (WHERE n>=2) AS still_multi FROM x`);
console.log('FLEET still-multi-manifest visits:', JSON.stringify(fleet));
// 5. ORPHAN check: removed manifests now with 0 visits
const orphans = await pg(`
  SELECT dm.id AS manifest_id, dm.white_manifest_number, (SELECT client_code FROM clients WHERE id=dm.client_id) AS code, (SELECT count(*) FROM manifest_visits mv WHERE mv.manifest_id=dm.id) AS n_visits
  FROM derm_manifests dm WHERE dm.id IN (${manIds.join(',')}) ORDER BY dm.id`);
console.log('removed-manifest visit counts (0 = orphaned, needs re-link to true owner):', JSON.stringify(orphans));
