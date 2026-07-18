// Re-runnable probe for the DUMP ETA action (Building Apps/DUMP Schedule/docs/09-eta-design.md).
//
// Usage:  node scripts/probes/dump_eta_probe.js [driver_id] [DH|DP]
//         EXPECT_ETA=1 node scripts/probes/dump_eta_probe.js     (asserts a real routed number;
//                                                                 requires GOOGLE_MAPS_API_KEY to be set)
//
// Asserts the SHAPE of every branch of action:"eta" against the DEPLOYED function. It deliberately does
// not assert that an ETA number came back unless EXPECT_ETA=1, because "no ETA" is a legitimate,
// designed outcome (stale truck fix, missing key, routing failure) and must never be reported as a bug.
const FN = "https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/dump-visit-create";

const post = async (payload) => {
  const r = await fetch(FN, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  let body;
  try { body = await r.json(); } catch { body = { parseError: true }; }
  return { status: r.status, body };
};

let fails = 0;
const check = (name, cond, detail) => {
  console.log(`${cond ? "PASS" : "FAIL"}  ${name}${detail ? "  :: " + detail : ""}`);
  if (!cond) fails++;
};

(async () => {
  const boot = await post({ action: "bootstrap" });
  const drivers = boot.body.drivers || [];
  const driverId = Number(process.argv[2] || drivers[0]?.id);
  const dump = process.argv[3] || "DH";
  console.log(`driver_id=${driverId} dump=${dump}\n`);

  // 1) truck path (no client coords): either a routed ETA, or an explicit ask-the-phone signal.
  const truck = await post({ action: "eta", driver_id: driverId, dump });
  console.log("TRUCK PATH:", JSON.stringify(truck.body));
  check("truck path returns ok", truck.body.ok === true, `status=${truck.status}`);
  check(
    "truck path is either an ETA or need_client_location",
    truck.body.need_client_location === true || "eta_minutes" in truck.body,
    JSON.stringify(truck.body),
  );

  // 2) phone path: a coordinate near the Miami yard must never ask for location again.
  const phone = await post({
    action: "eta", driver_id: driverId, dump,
    client_lat: 25.807032, client_lng: -80.206474,
  });
  console.log("PHONE PATH:", JSON.stringify(phone.body));
  check("phone path returns ok", phone.body.ok === true);
  check("phone path never asks again", phone.body.need_client_location !== true);
  check("phone path reports source=phone", phone.body.source === "phone", String(phone.body.source));

  // 3) out-of-range coords must be rejected, not routed.
  const bad = await post({ action: "eta", driver_id: driverId, dump, client_lat: 999, client_lng: 999 });
  console.log("BAD COORDS:", bad.status, JSON.stringify(bad.body));
  check("bad coords rejected with 400", bad.status === 400 && bad.body.ok === false);

  // 4) the destination is a server-side whitelist key; anything else is rejected.
  const badDump = await post({ action: "eta", driver_id: driverId, dump: "ZZ" });
  check("unknown dump rejected with 400", badDump.status === 400 && badDump.body.ok === false);

  // 5) driver is required.
  const noDrv = await post({ action: "eta", dump });
  check("missing driver rejected with 400", noDrv.status === 400 && noDrv.body.ok === false);

  // 6) with the key configured, the phone path must return a believable number.
  //    Miami yard -> Homestead is roughly 25 to 60 min depending on traffic; outside 3..180 is a bug.
  if (process.env.EXPECT_ETA === "1") {
    const real = await post({
      action: "eta", driver_id: driverId, dump: "DH",
      client_lat: 25.807032, client_lng: -80.206474,
    });
    console.log("REAL ETA:", JSON.stringify(real.body));
    const m = real.body.eta_minutes;
    check("routes returns a numeric eta", typeof m === "number", String(m));
    check("eta is believable (3..180 min)", typeof m === "number" && m >= 3 && m <= 180, String(m));
    check(
      "arrival_at is a valid near-future timestamp",
      !!real.body.arrival_at && new Date(real.body.arrival_at).getTime() > Date.now() - 60_000,
      String(real.body.arrival_at),
    );
    check("distance_mi present", typeof real.body.distance_mi === "number", String(real.body.distance_mi));
  } else {
    console.log("SKIP  real-ETA assertions (set EXPECT_ETA=1 once GOOGLE_MAPS_API_KEY is configured)");
  }

  console.log(`\n${fails === 0 ? "ALL CHECKS PASSED" : fails + " CHECK(S) FAILED"}`);
  process.exit(fails === 0 ? 0 : 1);
})();
