// ============================================================================
// normalize.js — Pure utility functions used across population steps
// ============================================================================

// Normalize a name string for fuzzy matching
function normName(s) {
  return String(s || '').toLowerCase().trim().replace(/\s+/g, ' ').replace(/[^\w\s]/g, '');
}

// Levenshtein distance (recursive DP)
function lev(a, b) {
  const m = a.length, n = b.length;
  if (!m) return n; if (!n) return m;
  const dp = Array.from({ length: m + 1 }, () => new Array(n + 1).fill(0));
  for (let i = 0; i <= m; i++) dp[i][0] = i;
  for (let j = 0; j <= n; j++) dp[0][j] = j;
  for (let i = 1; i <= m; i++)
    for (let j = 1; j <= n; j++)
      dp[i][j] = a[i - 1] === b[j - 1] ? dp[i - 1][j - 1] : 1 + Math.min(dp[i - 1][j], dp[i][j - 1], dp[i - 1][j - 1]);
  return dp[m][n];
}

function similarity(a, b) {
  a = normName(a); b = normName(b);
  if (!a || !b) return 0;
  return 1 - lev(a, b) / Math.max(a.length, b.length);
}

// Strip Fillout truck capacity suffix: "David 2,000" → "David", "Moises 3800" → "Moises"
function stripTruckSuffix(s) {
  return String(s || '').replace(/\s*[\d,]+\s*$/, '').replace(/\s+pickup\s*$/i, '').trim();
}

// Best fuzzy match within a candidate list
function bestFuzzyMatch(target, candidates, accessor = (x) => x.name, threshold = 0.85) {
  let best = null, bestScore = 0;
  for (const c of candidates) {
    const score = similarity(target, accessor(c));
    if (score > bestScore) { bestScore = score; best = c; }
  }
  if (bestScore >= threshold) return { match: best, score: bestScore };
  return null;
}

// Parse Airtable field with safe defaults
function atField(record, name, fallback = null) {
  return record.fields && record.fields[name] !== undefined ? record.fields[name] : fallback;
}

// Convert Airtable date string to YYYY-MM-DD
function dateOnly(d) {
  if (!d) return null;
  return String(d).slice(0, 10);
}

// Convert frequency in days from Airtable (assumed already in days)
function intOrNull(v) {
  if (v === null || v === undefined || v === '') return null;
  const n = Number(v);
  return isFinite(n) ? Math.round(n) : null;
}

function numOrNull(v) {
  if (v === null || v === undefined || v === '') return null;
  const n = Number(v);
  return isFinite(n) ? n : null;
}

function strOrNull(v) {
  if (v === null || v === undefined) return null;
  const s = String(v).trim();
  return s.length ? s : null;
}

// Decode Jobber base64 GID → numeric id (the part after the last slash)
function jobberGidNumeric(gid) {
  if (!gid) return null;
  try {
    const decoded = Buffer.from(gid, 'base64').toString('utf8');
    const m = decoded.match(/\/(\d+)$/);
    return m ? m[1] : null;
  } catch { return null; }
}

module.exports = {
  normName, lev, similarity, stripTruckSuffix, bestFuzzyMatch,
  atField, dateOnly, intOrNull, numOrNull, strOrNull, jobberGidNumeric,
};
