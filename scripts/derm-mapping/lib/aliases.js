// OCR-flywheel bridge: hydrate the pipeline's gazetteer from derm.client_aliases (the
// persistent, human-verified label store the Stamp Studio fills as a byproduct of
// stamping) and push refreshes back. Use in batch drivers:
//   const aliases = require('./lib/aliases');
//   const g = await aliases.hydrate(gz.load());   // file gazetteer + DB labels merged
//   ... run match workflow with { gazetteer: g } ...
//   await aliases.refresh();                       // after 03_load: fold new confirms in
// The DB is authoritative (survives machines/sessions); data/gazetteer.json remains a
// local cache. Alias rows ranked human-verify/manual-add > pipeline-high > canonical.
const { q } = require('./db');
const gz = require('./gazetteer');

async function hydrate(g) {
  g = g || { byAddr: {}, byName: {} };
  const rows = await q(`
    select a.alias_raw, c.client_code,
           case a.source when 'human-verify' then 3 when 'manual-add' then 3
                         when 'pipeline-high' then 2 else 1 end as rank
    from derm.client_aliases a join public.clients c on c.id = a.client_id
    where c.client_code is not null
    order by rank asc, a.times_confirmed asc`); // low->high so strongest wins the map
  let n = 0;
  for (const r of rows) {
    const nk = gz.norm(r.alias_raw);
    if (nk) { g.byName[nk] = r.client_code; n++; }
  }
  console.log(`aliases.hydrate: ${n} DB labels folded into gazetteer (byName now ${Object.keys(g.byName).length})`);
  return g;
}

// Re-derive DB aliases from all current high-trust rows (idempotent SQL fn).
async function refresh() {
  const r = await q('select * from derm.refresh_client_aliases()');
  console.log('aliases.refresh: client_aliases total =', r[0] && r[0].aliases_total);
  return r[0] && r[0].aliases_total;
}

module.exports = { hydrate, refresh };
