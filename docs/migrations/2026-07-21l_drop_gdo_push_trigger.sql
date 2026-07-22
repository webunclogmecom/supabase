-- ============================================================================
-- 2026-07-21l — Remove the GDO reporting event-PUSH trigger (bot self-manages)
-- ============================================================================
-- WHY (Fred 2026-07-21): the GDO Online Reporting bot manages its own flow — it
-- POLLS `rpa-derm-queue` on its own schedule and POSTs results to
-- `rpa-derm-result`; it does not need us to push it. The event-push path
-- (us -> the bot's /run) was built as an OPTIONAL low-latency alternative and
-- was never activated (the `app_config` keys rpa_run_url / rpa_run_key are
-- absent — verified empty). "The trigger depends on the bot" (Fred): the push
-- only makes sense if the bot exposes a /run we call, and the agreed model is
-- the reverse — the bot pulls. So this is dead architecture; remove it.
--
-- WHAT: drop the AFTER-INSERT trigger on public.manifest_visits and its
-- trigger function. Nothing else uses the function (verified: it backs only
-- this one trigger). The bot's read/write endpoints and every OTHER
-- manifest_visits trigger are untouched.
--
-- EXPLICITLY PRESERVED (do NOT drop — still load-bearing):
--   * public.fn_visit_is_gdo_reporting(bigint) — the code-27 eligibility
--     function the QUEUE view + rpa-derm-* endpoints depend on. The push
--     function called it, but it is NOT owned by the push path.
--   * The 6 other manifest_visits triggers: audit_manifest_visits,
--     trg_aa_link_same_client, trg_ab_link_one_white,
--     trg_ac_link_visit_not_after_dump, trg_zz_card_from_link,
--     zzz_broadcast_inval.
--
-- SAFETY: removal only, of a dormant no-op path. app_config push keys were
-- never set, so no config to clean. RPA_RUN_KEY (us->bot) in Supabase/.env is
-- now unused but left in place (harmless, gitignored). Reversible: re-create
-- from git history if the push model is ever revived.
-- ============================================================================

drop trigger if exists trg_zz_gdo_reporting_notify on public.manifest_visits;

drop function if exists public.trg_gdo_reporting_notify_bot();
