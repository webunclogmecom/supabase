// Generates docs/migrations/2026-08-21_2130_property_city_emails_per_property.sql
//
// 🛑 THE VIEW BODIES ARE GENERATED FROM THE LIVE pg_get_viewdef, NEVER RETYPED.
//    CREATE OR REPLACE VIEW takes the WHOLE body, so a hand-written one silently drops whatever you
//    failed to reproduce. derm.manifests alone is 7.7KB. Every edit below is an ANCHORED replace,
//    and each one ASSERTS it actually changed something: a no-op replace is a silent failure that
//    ships a view identical to the one you meant to change.
//
// Run: node scripts/probes/build_city_email_migration.mjs
import { readFileSync, writeFileSync } from 'node:fs';

const env = Object.fromEntries(readFileSync('.env', 'utf8').split(/\r?\n/).filter(l => /^[A-Z_]+=/.test(l))
  .map(l => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^"|"$/g, '').trim()]));
async function sql(q) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${env.SUPABASE_PROJECT_ID}/database/query`,
    { method: 'POST', headers: { Authorization: `Bearer ${env.SUPABASE_PAT}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ query: q }) });
  const t = await r.text(); let j; try { j = JSON.parse(t); } catch { throw new Error('non-JSON: ' + t.slice(0, 300)); }
  if (!Array.isArray(j)) throw new Error('mgmt error: ' + t.slice(0, 500)); return j;
}
const viewdef = async (v) => (await sql(`select pg_get_viewdef('${v}'::regclass, true) d`))[0].d;

// Replace-and-prove. Returns the new text, or throws naming the anchor that did not appear.
function must(text, from, to, label) {
  const n = text.split(from).length - 1;
  if (n === 0) throw new Error(`ANCHOR NOT FOUND (${label}): ${from.slice(0, 90)}`);
  console.log(`   ${label}: ${n} occurrence(s) replaced`);
  return text.split(from).join(to);
}

// The old predicate, verbatim from the live definitions of BOTH derm views.
const OLD_JOIN =
  `JOIN municipality_regulators mr ON lower(btrim(mr.municipality)) = lower(btrim(p.city)) AND mr.status = 'ACTIVE'::text`;
// Keeping the JOIN SHAPE and the alias `mr.municipality` is what makes this a minimal edit: the
// surrounding string_agg(DISTINCT mr.municipality) and EXISTS(...) keep working untouched, and the
// city name is now read off the property itself.
const NEW_JOIN =
  `JOIN LATERAL ( SELECT p.city AS municipality) mr ON cardinality(COALESCE(p.city_emails, '{}'::text[])) > 0`;

const parts = [readFileSync('scripts/probes/city_emails_header.sql', 'utf8')];
const add = (s) => parts.push(s);

console.log('generating...');

// ---------------------------------------------------------------- 1. the column
add(`
-- ---------------------------------------------------------------------------
-- 1. the per-property store
-- ---------------------------------------------------------------------------
ALTER TABLE public.properties
  ADD COLUMN IF NOT EXISTS city_emails text[] NOT NULL DEFAULT '{}'::text[];

COMMENT ON COLUMN public.properties.city_emails IS
  'City/regulator inbox for THIS property only. Per-property since 2026-08-21: editing one property '
  'must never change another, not even another property of the same client. Written only through '
  'client.update_property_city_email.';
`);

// ---------------------------------------------------------------- 2. backfill
add(`
-- ---------------------------------------------------------------------------
-- 2. backfill from the city rows, so nothing regresses
--    Surfside -> its properties, Hallandale Beach -> its properties.
-- 🛑 THE TEST ADDRESS IS EXCLUDED BY VALUE, NOT BY CITY NAME. Excluding "Miami" would be a rule
--    about the wrong thing: what disqualifies that row is that it holds a test address, and the
--    same guard then also catches any other row someone typed one into.
-- ---------------------------------------------------------------------------
UPDATE public.properties p
   SET city_emails = r.emails
  FROM public.municipality_regulators r
 WHERE r.status = 'ACTIVE'
   AND lower(btrim(r.municipality)) = lower(btrim(p.city))
   AND p.deleted_at IS NULL
   AND cardinality(COALESCE(r.emails, '{}'::text[])) > 0
   AND NOT EXISTS (SELECT 1 FROM unnest(r.emails) e
                    WHERE lower(e) LIKE '%@ayache.com' OR lower(e) LIKE '%fredzerpa%');
`);

// ---------------------------------------------------------------- 3. clear the test data
add(`
-- ---------------------------------------------------------------------------
-- 3. clear the test address everywhere (Fred: "remove it and let it be empty")
--    The ROW is kept, not deleted (rule 6); only the value is cleared, which is also what stops the
--    old RPC resurrecting it to ACTIVE on the next save.
-- ---------------------------------------------------------------------------
UPDATE public.municipality_regulators
   SET emails = '{}'::text[], status = 'INACTIVE'
 WHERE EXISTS (SELECT 1 FROM unnest(emails) e
                WHERE lower(e) LIKE '%@ayache.com' OR lower(e) LIKE '%fredzerpa%');

UPDATE public.properties
   SET city_emails = '{}'::text[]
 WHERE EXISTS (SELECT 1 FROM unnest(city_emails) e
                WHERE lower(e) LIKE '%@ayache.com' OR lower(e) LIKE '%fredzerpa%');
`);

// ---------------------------------------------------------------- 4. the views
let cp = await viewdef('client.properties');
console.log(' client.properties');
cp = must(cp, 'fn_city_regulator_emails(city) AS city_emails', 'p.city_emails', 'read the property');
add(`
-- ---------------------------------------------------------------------------
-- 4a. client.properties - the Client App property card
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW client.properties AS
${cp.trimEnd().replace(/;$/, '')};
`);

console.log(' public.v_visit_city_email (rewritten whole: 658 chars, small enough to be safer than an anchor)');
add(`
-- ---------------------------------------------------------------------------
-- 4b. public.v_visit_city_email
--     The '@' test is preserved from the original on purpose: the old view required the regulator
--     row to hold at least one address containing '@', so the replacement mirrors that rule rather
--     than paraphrasing it as "the array is non-empty".
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_visit_city_email AS
 SELECT v.id AS visit_id,
    p.city AS property_city,
    CASE WHEN EXISTS ( SELECT 1
             FROM unnest(COALESCE(p.city_emails, '{}'::text[])) e(e)
            WHERE e.e IS NOT NULL AND POSITION(('@'::text) IN (e.e)) > 0)
         THEN p.city ELSE NULL::text END AS regulator_municipality,
    (EXISTS ( SELECT 1
           FROM unnest(COALESCE(p.city_emails, '{}'::text[])) e(e)
          WHERE e.e IS NOT NULL AND POSITION(('@'::text) IN (e.e)) > 0)) AS city_email_on_file
   FROM v_visits_live v
     LEFT JOIN properties p ON p.id = v.property_id;
`);

for (const [v, label] of [['derm.manifest_recipients', '4c'], ['derm.manifests', '4d']]) {
  console.log(' ' + v);
  let body = await viewdef(v);
  body = must(body, OLD_JOIN, NEW_JOIN, 'city join -> property');
  add(`
-- ---------------------------------------------------------------------------
-- ${label}. ${v}
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW ${v} AS
${body.trimEnd().replace(/;$/, '')};
`);
}

// ---------------------------------------------------------------- 5. the RPC
add(`
-- ---------------------------------------------------------------------------
-- 5. the write path: ONE property, and nothing else
--    Still SECURITY DEFINER because \`authenticated\` holds no table-level UPDATE on
--    public.properties (only a 2-column grant), so the app cannot write this directly.
--    search_path is pinned, as it was before.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION client.update_property_city_email(p_property_id bigint, p_emails text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_clean text[];
  v_bad   text;
  v_city  text;
begin
  if p_property_id is null then
    raise exception 'A property id is required.' using errcode = '22023';
  end if;

  select btrim(p.city) into v_city
    from public.properties p
   where p.id = p_property_id and p.deleted_at is null;

  if not found then
    raise exception 'Property % does not exist.', p_property_id using errcode = '22023';
  end if;

  -- normalise: trim, lower-case, drop blanks, de-duplicate, stable order
  select array_agg(e ORDER BY e)
    into v_clean
    from (select distinct lower(btrim(x)) as e
            from unnest(coalesce(p_emails, '{}'::text[])) as x
           where btrim(x) <> '') s;
  v_clean := coalesce(v_clean, '{}'::text[]);

  select e into v_bad
    from unnest(v_clean) e
   where e !~ '^[^[:space:]@]+@[^[:space:]@]+\\.[^[:space:]@]+$'
   limit 1;
  if v_bad is not null then
    raise exception 'That does not look like an email address: %', v_bad using errcode = '22023';
  end if;

  -- 🛑 ONE ROW. The p.id predicate is the whole point of this migration: the previous version
  --    resolved the property's CITY and wrote a shared row, so this same call changed 230
  --    properties across 114 clients.
  update public.properties
     set city_emails = v_clean
   where id = p_property_id;

  return jsonb_build_object(
    'property_id', p_property_id,
    'city',        v_city,
    'emails',      to_jsonb(v_clean)
  );
end;
$function$;

REVOKE ALL ON FUNCTION client.update_property_city_email(bigint, text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION client.update_property_city_email(bigint, text[])
  TO authenticated, service_role;
`);

add(`
COMMIT;
`);

const outPath = 'docs/migrations/2026-08-21_2130_property_city_emails_per_property.sql';
writeFileSync(outPath, parts.join('\n'));
console.log(`\nwrote ${outPath} (${parts.join('\n').length} bytes)`);
