// calendar-date-picker-local.mjs: the Calendar's date picker must never be handed a date built at midnight UTC.
// Trello N1ftXDIX, 2026-11-06: DateTime.fromISO(value, { zone: "utc" }).toJSDate() made the month highlight the day before for anyone on
// Eastern time, and a date on the 1st opened the month before. It looks right on a machine in Europe, so only a check like this sees it.
//   node scripts/checks/calendar-date-picker-local.mjs
// Reads the live bundles of every host that serves the Calendar (no sign-in, nothing written). Exit 1 if the pattern is back.
const HOSTS = ['https://calendar.unclogme.app/', 'https://ops.unclogme.app/'];
const BAD = /zone:\s*["'`]utc["'`]\s*\}\)\.toJSDate\(/g;
// the words of the task dialog: if no chunk holds them, this read the wrong files and proves nothing
const LANDMARK = 'Leave empty for all-day';

// positive control: the pattern must match what it exists to catch, and must not match the fix
const control = ['DateTime.fromISO(a,{zone:"utc"}).toJSDate()', 'o.fromISO(e, { zone: `utc` }).toJSDate()'];
if (!control.every((s) => s.match(BAD)) || 'DateTime.fromISO(a).toJSDate()'.match(BAD)) { console.error('FAIL: the pattern itself is broken'); process.exit(1); }

let failed = false;
for (const host of HOSTS) {
  const seen = new Set(), queue = [''];
  let landmark = 0, bad = 0, files = 0;
  while (queue.length && files < 600) {
    const path = queue.shift();
    const res = await fetch(host + path);
    if (!res.ok) continue;
    const text = await res.text();
    files++;
    if (path) { bad += (text.match(BAD) || []).length; if (text.includes(LANDMARK)) landmark++; }
    for (const m of text.matchAll(/(?:assets\/)?[\w.-]+-[\w-]{6,}\.js/g)) {
      const p = m[0].startsWith('assets/') ? m[0] : 'assets/' + m[0];
      if (!seen.has(p)) { seen.add(p); queue.push(p); }
    }
  }
  const ok = landmark > 0 && bad === 0;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${host}: ${files} files read, ${landmark} hold the task dialog, ${bad} hand the picker a UTC date`);
  if (!ok) failed = true;
}
process.exit(failed ? 1 : 0);
