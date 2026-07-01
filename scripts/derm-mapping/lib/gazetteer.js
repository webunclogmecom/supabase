// Confirmed facility->client memory, learned across sheets. Keyed by normalized street#+zip and by
// normalized facility name. Only CONFIRMED matches (unanimous+consistent, or human-reviewed) go in.
const fs = require('fs');
const path = require('path');
const FILE = path.resolve(__dirname, '../data/gazetteer.json');
const norm = s => String(s || '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
const addrKey = a => { const s = String(a || ''); const zips = [...s.matchAll(/\b(3\d{4})\b/g)]; if (!zips.length) return null; const z = zips[zips.length - 1]; const num = (s.slice(0, z.index).match(/\b(\d{2,6})\b/) || [])[1]; return num ? num + '|' + z[1] : null; };
function load() { try { return JSON.parse(fs.readFileSync(FILE, 'utf8')); } catch (e) { return { byAddr: {}, byName: {} }; } }
function save(g) { fs.mkdirSync(path.dirname(FILE), { recursive: true }); fs.writeFileSync(FILE, JSON.stringify(g, null, 2)); }
function lookup(g, name, address) {
  const ak = addrKey(address); if (ak && g.byAddr[ak]) return g.byAddr[ak];
  const nk = norm(name); if (nk && g.byName[nk]) return g.byName[nk];
  return null;
}
// rows: [{facility_name_read, address_read, matched_client_code}] that are CONFIRMED.
function merge(g, rows) {
  for (const r of rows) {
    if (!r.matched_client_code) continue;
    const ak = addrKey(r.address_read); if (ak) g.byAddr[ak] = r.matched_client_code;
    const nk = norm(r.facility_name_read); if (nk) g.byName[nk] = r.matched_client_code;
  }
  return g;
}
module.exports = { load, save, lookup, merge, addrKey, norm };
