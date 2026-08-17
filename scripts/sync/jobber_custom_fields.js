#!/usr/bin/env node
/**
 * Shared plumbing for the Jobber custom-field two-way sync.
 *
 * WHAT THIS IS FOR
 *   Yannick 2026-08-17: custom fields like Grease Trap size "should be two-way, if
 *   it's us or in jobber that change it the other should adopt". Fred pinned the
 *   safe shape: "only when a change is made we need to adopt."
 *
 * 🛑 WHY "ONLY WHEN A CHANGE IS MADE" IS NOT A PREFERENCE. Jobber's numeric custom
 *   field has defaultValue 0, is materialised on every property, and carries NO
 *   updatedAt. A property nobody ever touched is byte-identical to one where a
 *   human deliberately typed 0. Copying Jobber's value in would zero 69 of our
 *   properties (47,732 gallons) and overwrite 10 more, 9 of them downward, to gain
 *   3. 79 of 105 values damaged, silently, because the CHECK permits 0.
 *   The decision therefore compares against sync.source_field_shadow (what we LAST
 *   SAW), never against the value itself. Full reasoning:
 *   docs/migrations/2026-08-17_1636_jobber_custom_field_shadow.sql
 *
 * 🛑 BIND BY CONFIGURATION GID, NEVER BY LABEL. Four numeric grease-trap fields
 *   exist in the account and TWO of them share the label "GT size"; two more differ
 *   only by a capital S. A label match picks the wrong field today, not someday.
 *     3061111  "Grease Trap size"  ALL_PROPERTIES   <- the only one in scope
 *     3061109  "Grease Trap Size"  ALL_JOBS         (archived)
 *     3070341  "GT size"           ALL_JOBS
 *     3070342  "GT size"           ALL_INVOICES
 *
 * Read-only by itself. Writes nothing. Required by:
 *   scripts/sync/seed_jobber_custom_field_shadow.js
 *   scripts/sync/adopt_jobber_custom_fields.js
 */
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');

// ---------------------------------------------------------------------------
// THE FIELD REGISTRY. Adding a field here needs NO migration: the shadow store is
// keyed by (entity, source_system, field_key) and holds bare jsonb scalars.
// Only add a field once Fred has said to wire it.
// ---------------------------------------------------------------------------
const FIELDS = [
  {
    id: 'grease_trap_size',
    // The BINDING. Canonical, un-encoded form; Jobber returns it base64 and the
    // comparison normalises both sides.
    fieldKey: 'gid://Jobber/CustomFieldConfigurationNumeric/3061111',
    label: 'Grease Trap size',        // informational ONLY. Never match on this.
    appliesTo: 'ALL_PROPERTIES',
    kind: 'numeric',                  // 'numeric' | 'text'
    entityType: 'property',           // entity_source_links / shadow vocabulary
    sourceSystem: 'jobber',
    ourTable: 'public.properties',
    ourColumn: 'grease_trap_size_gallons',
    // public.properties_grease_trap_size_chk: NULL, or 0..20000 inclusive.
    // An adopt outside this range is refused rather than left to raise 23514.
    ourMin: 0,
    ourMax: 20000,
    // 🛑 An adopt whose new value is null or 0 DESTROYS a recorded capacity. It is a
    // legitimate outcome (a human cleared the field in Jobber) but it is the single
    // most damaging thing this sync can do, so it needs --allow-clear to fire.
    clearingIsDangerous: true,
  },
];

// ⚠ OUT OF SCOPE, listed so nobody "completes the set" by accident.
// "CLIENT #" (gid://Jobber/CustomFieldConfigurationText/3087457, ALL_PROPERTIES) is
// populated on 1 of 474 properties, its only value is a list of restaurant names,
// and it is NOT clients.client_code. Fred has not said what it is for. Do not wire it.

// ---------------------------------------------------------------------------
// env + Management API
// ---------------------------------------------------------------------------
const env = Object.fromEntries(
  fs.readFileSync(path.join(ROOT, '.env'), 'utf8')
    .split(/\r?\n/).filter((l) => l.includes('=') && !l.trim().startsWith('#'))
    .map((l) => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim()]; })
);

async function sql(query) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${env.SUPABASE_PROJECT_ID}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${env.SUPABASE_PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query }),
  });
  const t = await r.text();
  // Do not truncate: a raised matrix from a DO block arrives in this body.
  if (!r.ok) throw new Error(t);
  return JSON.parse(t);
}

// SQL literal for a text value. Everything user-visible that reaches a statement
// goes through this; the field registry is code-controlled but the labels are not
// worth an exception.
const lit = (s) => (s === null || s === undefined ? 'null' : `'${String(s).replace(/'/g, "''")}'`);
// A bare jsonb scalar. JSON.stringify(null) === 'null', which is the JSON null we
// want, and is deliberately NOT a SQL NULL: source_value/our_value are NOT NULL and
// a missing ROW is what means "never looked".
const jlit = (v) => `${lit(JSON.stringify(v === undefined ? null : v))}::jsonb`;

// ---------------------------------------------------------------------------
// Jobber
// ---------------------------------------------------------------------------
function token() {
  // ⚠ execSync uses cmd.exe on Windows, where "./jobber-token.sh" is not a command.
  // It must be handed to bash explicitly.
  return execSync('bash ./jobber-token.sh', {
    cwd: path.join(ROOT, '..', 'Slack'), encoding: 'utf8',
  }).trim().split(/\r?\n/).filter(Boolean).pop();
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * gql with backoff, copied from scripts/probes/sweep_michael_visits.js.
 *
 * 🛑 THE CONTENT-TYPE CHECK IS NOT OPTIONAL. Jobber sheds load with an HTML
 * "waiting room" at HTTP 200, with no errors array. r.json() then throws, the
 * catch-and-continue idiom turns it into {}, and the caller receives ok:true with
 * data:undefined. Every downstream `?? null` / `|| []` / `?.` coerces that missing
 * answer into a neutral value and the comparison passes by comparing nothing to
 * nothing. For THIS script that would look like "every property's custom field is
 * now empty", i.e. a fleet-wide clearing event. See CLAUDE.md.
 */
async function gql(tok, query, variables) {
  for (let attempt = 0; attempt < 8; attempt++) {
    const r = await fetch('https://api.getjobber.com/api/graphql', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${tok}`,
        'X-JOBBER-GRAPHQL-VERSION': '2026-04-16',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ query, variables }),
    });
    const ctype = r.headers.get('content-type') ?? '';
    if (!ctype.includes('json')) {
      console.log(`  non-JSON (${ctype}) at HTTP ${r.status}; Jobber waiting room, backing off 30s`);
      await sleep(30000); continue;
    }
    const j = await r.json();
    const throttled = (j.errors || []).some((e) => e?.extensions?.code === 'THROTTLED');
    if (throttled) {
      const wait = 20000 * (attempt + 1);
      console.log(`  throttled, waiting ${wait / 1000}s`);
      await sleep(wait); continue;
    }
    if (j.errors) throw new Error(JSON.stringify(j.errors).slice(0, 400));
    // Require the read to have HAPPENED. A well-formed response with no data key is
    // still a missing answer, and a missing answer must never be read as "empty".
    if (!j.data) throw new Error('Jobber returned JSON with no data key');
    return j.data;
  }
  throw new Error('still throttled after 8 attempts');
}

/** Jobber returns GIDs base64-encoded. Normalise both sides before comparing. */
function decodeGid(s) {
  if (typeof s !== 'string' || !s) return s;
  if (s.startsWith('gid://')) return s;
  try {
    const d = Buffer.from(s, 'base64').toString('utf8');
    return d.startsWith('gid://') ? d : s;
  } catch { return s; }
}

const PROPERTY_QUERY = `query($first:Int!,$after:String){
  properties(first:$first, after:$after){
    totalCount
    pageInfo { hasNextPage endCursor }
    nodes {
      id
      customFields {
        __typename
        ... on CustomFieldNumeric { id label valueNumeric
              customFieldConfiguration { id name appliesTo readOnly } }
        ... on CustomFieldText    { id label valueText
              customFieldConfiguration { id name appliesTo readOnly } }
      }
    }
  } }`;

/**
 * Page every Jobber property, returning Map<decodedPropertyGid, {
 *   raw, byConfig: Map<decodedConfigGid, { value, kind, readOnly, materialised }>
 * }>.
 *
 * `materialised` records whether Jobber actually returned a row for that config, as
 * opposed to us defaulting it. That distinction is the instrument control: if the
 * selection silently stops returning the field, every property looks "empty", and
 * the callers refuse to write rather than record a fleet of nulls.
 */
async function fetchJobberProperties({ pageSize = 25, pageSleepMs = 3000, limit = Infinity } = {}) {
  const tok = token();
  const out = new Map();
  let after = null, total = null, pages = 0;
  do {
    const d = await gql(tok, PROPERTY_QUERY, { first: pageSize, after });
    const c = d.properties;
    total = c.totalCount;
    for (const n of c.nodes) {
      const byConfig = new Map();
      for (const f of n.customFields ?? []) {
        const cfg = decodeGid(f?.customFieldConfiguration?.id);
        if (!cfg) continue;
        const kind = f.__typename === 'CustomFieldNumeric' ? 'numeric'
                   : f.__typename === 'CustomFieldText' ? 'text' : null;
        if (!kind) continue;
        byConfig.set(cfg, {
          value: kind === 'numeric' ? (f.valueNumeric ?? null) : (f.valueText ?? null),
          kind,
          label: f.label ?? null,
          readOnly: f.customFieldConfiguration?.readOnly ?? null,
          materialised: true,
        });
      }
      out.set(decodeGid(n.id), { byConfig });
    }
    pages += 1;
    process.stdout.write(`\r  jobber: ${out.size}/${total} properties (${pages} pages)`);
    after = c.pageInfo.hasNextPage ? c.pageInfo.endCursor : null;
    if (after && out.size < limit) await sleep(pageSleepMs);
  } while (after && out.size < limit);
  process.stdout.write('\n');
  return { properties: out, total };
}

/**
 * Our side: every property that carries a REAL Jobber Property GID link.
 *
 * 🛑 THE _billing FILTER IS LOAD-BEARING. entity_source_links holds 885 rows for
 * (property, jobber) but 426 of them are a synthesized "<clientGID>_billing"
 * pseudo-key that decodes to a CLIENT gid, not a property. Only 459 are real. Join
 * without this filter and the billing rows match nothing at the Jobber end, which
 * reads as "426 properties missing from Jobber" and is pure noise.
 */
async function loadOurProperties(field) {
  const rows = await sql(`
    select l.source_id                       as gid_b64,
           p.id                              as property_id,
           p.name                            as property_name,
           p.${field.ourColumn}              as our_value,
           s.source_value::text              as shadow_source_value,
           s.our_value::text                 as shadow_our_value,
           s.conflict_at is not null         as shadow_in_conflict,
           (s.entity_id is not null)         as shadow_exists
      from public.entity_source_links l
      join public.properties p on p.id = l.entity_id
      left join sync.source_field_shadow s
             on s.entity_type   = ${lit(field.entityType)}
            and s.entity_id     = p.id
            and s.source_system = ${lit(field.sourceSystem)}
            and s.field_key     = ${lit(field.fieldKey)}
     where l.entity_type   = 'property'
       and l.source_system = 'jobber'
       and l.source_id not like '%\\_billing'
     order by p.id`);
  return rows.map((r) => ({ ...r, gid: decodeGid(r.gid_b64) }));
}

function fieldById(id) {
  const f = FIELDS.find((x) => x.id === id);
  if (!f) throw new Error(`unknown field "${id}"; known: ${FIELDS.map((x) => x.id).join(', ')}`);
  return f;
}

module.exports = {
  FIELDS, fieldById, env, sql, lit, jlit,
  token, gql, sleep, decodeGid,
  fetchJobberProperties, loadOurProperties, PROPERTY_QUERY,
};
