// ============================================================================
// Visit View — Data + Rendering (prototype)
// ----------------------------------------------------------------------------
// What this is:
//   A standalone, dependency-free prototype that fetches upcoming visits from
//   the Supabase REST API and renders them grouped by day or by client.
//
// Why dependency-free:
//   Yannick is going to rebuild this in Lovable. Everything here is meant to
//   be obvious — design tokens, layout primitives, data shape — so that the
//   Lovable handoff is "here's the visual + here's the schema queries", not
//   "decode this build system".
//
// Auth model in the prototype:
//   Reads from the public anon role with row-level security policies that
//   allow SELECT on visits/clients/service_configs. Same shape Yannick has
//   in his Sandbox app already. For prod, swap to authenticated role.
// ============================================================================

// ---- Config -----------------------------------------------------------------
const SUPABASE_URL  = window.SUPABASE_URL  || 'https://wbasvhvvismukaqdnouk.supabase.co';
const SUPABASE_ANON = window.SUPABASE_ANON || ''; // injected at deploy; empty in prototype-only mode

// Mock data so the prototype renders without credentials. Swap MOCK→false +
// drop a SUPABASE_ANON token to point at real data.
const MOCK = !SUPABASE_ANON;

// ---- DOM refs ---------------------------------------------------------------
const elList     = document.getElementById('list');
const elCount    = document.getElementById('count-pill');
const elSearch   = document.getElementById('q');
const elSvcSel   = document.getElementById('service-filter');
const elBtnDay   = document.getElementById('group-day');
const elBtnClient= document.getElementById('group-client');

// ---- State ------------------------------------------------------------------
const state = {
  visits: [],
  grouping: 'day',     // 'day' | 'client'
  search: '',
  serviceType: '',
};

// ---- Wire toolbar -----------------------------------------------------------
elSearch.addEventListener('input', e => { state.search = e.target.value.toLowerCase(); render(); });
elSvcSel.addEventListener('change', e => { state.serviceType = e.target.value; render(); });
elBtnDay.addEventListener('click', () => setGrouping('day'));
elBtnClient.addEventListener('click', () => setGrouping('client'));
function setGrouping(g) {
  state.grouping = g;
  elBtnDay.setAttribute('aria-pressed', g === 'day');
  elBtnClient.setAttribute('aria-pressed', g === 'client');
  render();
}

// ---- Fetch ------------------------------------------------------------------
async function fetchVisits() {
  if (MOCK) {
    // Realistic shape — mirrors the Sbx query result for upcoming visits
    return MOCK_VISITS;
  }
  // Real Supabase REST. The query selects upcoming visits with client info
  // inlined via PostgREST's resource embedding. RLS on the public anon role
  // gates what gets returned.
  const q = new URLSearchParams({
    select: 'id,visit_date,visit_status,service_type,title,client_id,clients(client_code,name)',
    visit_status: 'eq.scheduled',
    visit_date: `gte.${todayISO()}`,
    order: 'visit_date.asc',
    limit: '500',
  });
  const r = await fetch(`${SUPABASE_URL}/rest/v1/visits?${q}`, {
    headers: { apikey: SUPABASE_ANON, Authorization: `Bearer ${SUPABASE_ANON}` },
  });
  if (!r.ok) throw new Error(`Supabase ${r.status}: ${await r.text()}`);
  return await r.json();
}

// ---- Render -----------------------------------------------------------------
function render() {
  const filtered = state.visits.filter(v => {
    if (state.serviceType && v.service_type !== state.serviceType) return false;
    if (state.search) {
      const hay = (v.title + ' ' + (v.clients?.client_code || '') + ' ' + (v.clients?.name || '')).toLowerCase();
      if (!hay.includes(state.search)) return false;
    }
    return true;
  });

  elCount.textContent = `${filtered.length} visit${filtered.length === 1 ? '' : 's'}`;

  if (filtered.length === 0) {
    elList.innerHTML = `
      <div class="u-state">
        <p class="u-state__title">No upcoming visits match.</p>
        <p class="u-state__hint">Adjust the filters or check back tomorrow — the cron runs daily at 4:30 AM ET.</p>
      </div>`;
    return;
  }

  const groups = state.grouping === 'day' ? groupByDay(filtered) : groupByClient(filtered);
  elList.innerHTML = groups.map(group => `
    <section class="u-day" aria-labelledby="grp-${escapeAttr(group.key)}">
      <header class="u-day__heading">
        <div>
          <span class="u-day__eyebrow">${escapeHtml(group.eyebrow)}</span>
          <h2 class="u-day__title" id="grp-${escapeAttr(group.key)}">${escapeHtml(group.title)}</h2>
        </div>
        <span class="u-day__count">${group.items.length} visit${group.items.length === 1 ? '' : 's'}</span>
      </header>
      <ul class="u-visits">
        ${group.items.map(visitCard).join('')}
      </ul>
    </section>
  `).join('');
}

function visitCard(v) {
  const dateObj = new Date(v.visit_date + 'T12:00:00');
  const day = dateObj.getUTCDate();
  const monthShort = dateObj.toLocaleDateString('en-US', { month: 'short', timeZone: 'UTC' });
  const weekday = dateObj.toLocaleDateString('en-US', { weekday: 'short', timeZone: 'UTC' });
  const clientName = v.clients?.name || v.title || 'Unknown';
  const clientCode = v.clients?.client_code || '—';
  const svc = v.service_type || '—';

  return `
    <li class="u-visit">
      <span class="u-visit__type u-visit__type--${svc}" title="${escapeAttr(serviceLabel(svc))}">${svc}</span>
      <div class="u-visit__body">
        <div class="u-visit__title">${escapeHtml(clientName)}</div>
        <div class="u-visit__meta">
          <span>${escapeHtml(clientCode)}</span>
          <span class="u-visit__meta-dot" aria-hidden="true"></span>
          <span>${escapeHtml(serviceLabel(svc))}</span>
        </div>
      </div>
      <div class="u-visit__right">
        <span class="u-visit__status u-visit__status--${escapeAttr(v.visit_status)}">${escapeHtml(v.visit_status)}</span>
        <div class="u-visit__date">
          <div class="u-visit__date-day">${day}</div>
          <div>${escapeHtml(weekday)} · ${escapeHtml(monthShort)}</div>
        </div>
      </div>
    </li>
  `;
}

// ---- Grouping ---------------------------------------------------------------
function groupByDay(visits) {
  const byKey = new Map();
  for (const v of visits) {
    const key = v.visit_date;
    if (!byKey.has(key)) byKey.set(key, []);
    byKey.get(key).push(v);
  }
  return [...byKey.entries()].sort((a, b) => a[0].localeCompare(b[0])).map(([key, items]) => {
    const d = new Date(key + 'T12:00:00');
    const longDate = d.toLocaleDateString('en-US', {
      weekday: 'long', month: 'long', day: 'numeric', year: 'numeric', timeZone: 'UTC'
    });
    const relative = relativeDay(key);
    return { key, eyebrow: relative, title: longDate, items };
  });
}
function groupByClient(visits) {
  const byKey = new Map();
  for (const v of visits) {
    const key = v.clients?.client_code || v.client_id?.toString() || '—';
    if (!byKey.has(key)) byKey.set(key, []);
    byKey.get(key).push(v);
  }
  return [...byKey.entries()].sort((a, b) => a[0].localeCompare(b[0])).map(([key, items]) => {
    const sample = items[0]?.clients?.name || items[0]?.title || key;
    return { key, eyebrow: key, title: sample, items };
  });
}

// ---- Helpers ----------------------------------------------------------------
function todayISO() {
  return new Date().toISOString().slice(0, 10);
}
function relativeDay(iso) {
  const today = todayISO();
  if (iso === today) return 'Today';
  const t = new Date(today + 'T00:00:00');
  const d = new Date(iso + 'T00:00:00');
  const diff = Math.round((d - t) / 86400000);
  if (diff === 1) return 'Tomorrow';
  if (diff > 1 && diff <= 7) return `In ${diff} days`;
  if (diff < 0) return `${Math.abs(diff)}d ago`;
  return iso;
}
function serviceLabel(s) {
  return { GT: 'Grease Trap', CL: 'Cleaning', WD: 'Water Discharge', LS: 'Lyft Station' }[s] || s;
}
function escapeHtml(s) {
  return String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
function escapeAttr(s) {
  return escapeHtml(s).replace(/\s+/g, '-');
}

// ---- Boot -------------------------------------------------------------------
(async () => {
  try {
    state.visits = await fetchVisits();
    render();
  } catch (e) {
    elList.innerHTML = `<div class="u-state"><p class="u-state__title">Couldn't load visits.</p><p class="u-state__hint">${escapeHtml(e.message)}</p></div>`;
  }
})();

// ============================================================================
// MOCK DATA — representative shape, ~12 visits across the next 2 weeks
// ============================================================================
const MOCK_VISITS = (() => {
  const today = new Date();
  const isoFromOffset = (days) => {
    const d = new Date(today); d.setDate(d.getDate() + days);
    return d.toISOString().slice(0, 10);
  };
  return [
    { id: 4001, visit_date: isoFromOffset(0), visit_status: 'scheduled', service_type: 'GT', title: '004-BAO Baoli Miami - Scheduled GT', client_id: 4,  clients: { client_code: '004-BAO', name: 'Baoli Miami' } },
    { id: 4002, visit_date: isoFromOffset(0), visit_status: 'scheduled', service_type: 'CL', title: '011-MX Mexican Cantina - Scheduled CL', client_id: 11, clients: { client_code: '011-MX',  name: 'Mexican Cantina' } },
    { id: 4003, visit_date: isoFromOffset(1), visit_status: 'scheduled', service_type: 'GT', title: '042-MT Miami Twist - Scheduled GT', client_id: 42, clients: { client_code: '042-MT',  name: 'Miami Twist' } },
    { id: 4004, visit_date: isoFromOffset(1), visit_status: 'scheduled', service_type: 'LS', title: '057-BAY Bayshore - Lyft station cleaning', client_id: 57, clients: { client_code: '057-BAY', name: 'Bayshore Executive Plaza' } },
    { id: 4005, visit_date: isoFromOffset(2), visit_status: 'scheduled', service_type: 'GT', title: '174-VIN Vincenzos - Scheduled GT', client_id: 174, clients: { client_code: '174-VIN', name: "Vincenzo's Pizzeria" } },
    { id: 4006, visit_date: isoFromOffset(3), visit_status: 'scheduled', service_type: 'WD', title: '075-TCE - WD service', client_id: 75, clients: { client_code: '075-TCE', name: 'The Carrot Express Fort Lauderdale' } },
    { id: 4007, visit_date: isoFromOffset(4), visit_status: 'scheduled', service_type: 'CL', title: '110-CLA Claudie - Scheduled CL', client_id: 110, clients: { client_code: '110-CLA', name: 'Claudie' } },
    { id: 4008, visit_date: isoFromOffset(5), visit_status: 'scheduled', service_type: 'GT', title: '199-JZ JZ Steak House - Scheduled GT', client_id: 199, clients: { client_code: '199-JZ',  name: 'JZ Steak House' } },
    { id: 4009, visit_date: isoFromOffset(7), visit_status: 'scheduled', service_type: 'GT', title: '003-BC - Scheduled GT', client_id: 3, clients: { client_code: '003-BC',  name: 'BC Bagels' } },
    { id: 4010, visit_date: isoFromOffset(8), visit_status: 'scheduled', service_type: 'CL', title: '169-TCE - Scheduled CL', client_id: 169, clients: { client_code: '169-TCE', name: 'The Carrot Express Oakland Park' } },
    { id: 4011, visit_date: isoFromOffset(10), visit_status: 'scheduled', service_type: 'GT', title: '147-OST Maison Ostrow - Scheduled GT', client_id: 147, clients: { client_code: '147-OST', name: 'Maison Ostrow' } },
    { id: 4012, visit_date: isoFromOffset(12), visit_status: 'scheduled', service_type: 'GT', title: '205-SAS Signor Sassi - Scheduled GT', client_id: 205, clients: { client_code: '205-SAS', name: 'Signor Sassi' } },
  ];
})();
