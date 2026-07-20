// Re-runnable probe for the DUMP manifest hand-out + site hours
// (Building Apps/DUMP Schedule/docs/11-manifest-handout-design.md).
//
// Usage: node scripts/probes/dump_manifest_probe.js
//
// Asserts the shape of every branch against the DEPLOYED function. It deliberately does NOT assert that
// the list is non-empty: an empty list is a legitimate state (everything already documented) and must
// never be reported as a failure. What it DOES assert is that an error never masquerades as an empty
// list, which is the failure mode that would make a driver skip real DERM paperwork.
const FN = "https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/dump-visit-create";

const post = async (p) => {
  const r = await fetch(FN, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(p) });
  let b; try { b = await r.json(); } catch { b = { parseError: true }; }
  return { status: r.status, body: b };
};

let fails = 0;
const check = (n, c, d) => { console.log(`${c ? "PASS" : "FAIL"}  ${n}${d ? "  :: " + d : ""}`); if (!c) fails++; };

(async () => {
  const boot = await post({ action: "bootstrap" });
  const drivers = boot.body.drivers || [];
  const driverId = Number(process.argv[2] || drivers[0]?.id);
  console.log(`driver_id=${driverId}\n`);

  // 1. the hours verdict rides along with the ETA response, per dump
  const etas = await post({ action: "etas", driver_id: driverId, client_lat: 25.807, client_lng: -80.206 });
  console.log("ETAS:", JSON.stringify(etas.body).slice(0, 320));
  check("etas returns ok", etas.body.ok === true, `status=${etas.status}`);
  check("etas carries a site_status for BOTH dumps",
    !!etas.body.etas?.DH?.site_status && !!etas.body.etas?.DP?.site_status,
    JSON.stringify({ DH: etas.body.etas?.DH?.site_status, DP: etas.body.etas?.DP?.site_status }));
  check("site_status is one of the three verdicts",
    ["OPEN", "AFTER_HOURS", "CLOSED"].includes(etas.body.etas?.DH?.site_status),
    String(etas.body.etas?.DH?.site_status));
  check("Homestead carries the after-hours phone only when AFTER_HOURS",
    etas.body.etas?.DH?.site_status !== "AFTER_HOURS" || etas.body.etas?.DH?.after_hours_phone === "786-268-5623",
    String(etas.body.etas?.DH?.after_hours_phone));

  // 2. the manifest action validates its inputs
  const noDrv = await post({ action: "manifest", dump_visit_id: 1 });
  check("manifest without driver rejected 400", noDrv.status === 400 && noDrv.body.ok === false, JSON.stringify(noDrv.body));
  const noDump = await post({ action: "manifest", driver_id: driverId });
  check("manifest without dump_visit_id rejected 400", noDump.status === 400 && noDump.body.ok === false, JSON.stringify(noDump.body));

  // 3. a real dump visit returns the two buckets
  const real = await post({ action: "manifest", driver_id: driverId, dump_visit_id: Number(process.env.DUMP_VISIT_ID || 0) });
  if (process.env.DUMP_VISIT_ID) {
    console.log("MANIFEST:", JSON.stringify(real.body).slice(0, 320));
    check("manifest returns ok", real.body.ok === true);
    check("manifest returns both buckets as arrays",
      Array.isArray(real.body.load) && Array.isArray(real.body.outstanding),
      JSON.stringify({ load: typeof real.body.load, outstanding: typeof real.body.outstanding }));
    check("count matches the two buckets summed",
      real.body.count === (real.body.load.length + real.body.outstanding.length),
      `${real.body.count} vs ${real.body.load?.length}+${real.body.outstanding?.length}`);
    check("no visit appears in both buckets",
      !real.body.load.some((l) => real.body.outstanding.some((o) => o.visit_id === l.visit_id)));
  } else {
    // With no DUMP_VISIT_ID we send 0, which is not a real visit. Rejecting it is the CORRECT behaviour:
    // silently returning an empty list for a bogus dump would be the dangerous direction.
    check("a bogus dump_visit_id is rejected, not answered with an empty list",
      real.status === 400 && real.body.ok === false, JSON.stringify(real.body).slice(0, 160));
    console.log("SKIP  real-dump assertions (set DUMP_VISIT_ID=<id> to run them)");
  }

  console.log(`\n${fails === 0 ? "ALL CHECKS PASSED" : fails + " CHECK(S) FAILED"}`);
  process.exit(fails === 0 ? 0 : 1);
})();
