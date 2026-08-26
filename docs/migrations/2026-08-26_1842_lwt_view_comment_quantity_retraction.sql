-- 2026-08-26_1842_lwt_view_comment_quantity_retraction.sql
--
-- The view's OWN comment still asserted the claim retracted earlier today.
--
-- The retraction ("the filed quantity is the truck capacity resolved from the decal" is FALSE;
-- the county bills MEASURED gallons per manifest off the invoice) was applied to the Postman
-- README, two comment blocks in rpa-derm-monthly, and the Postman assertion messages. It did not
-- reach three places: the Postman request labelled START HERE, docs/schema.md line 669, and this,
-- the comment on the view itself. All three are fixed today.
--
-- ⚠ This one matters most of the three even though no external caller can read it. A view's own
-- COMMENT is what the next engineer or agent treats as the contract when they inspect the object,
-- and it is where the wrong claim propagated FROM in the first place. Leaving it would have
-- re-seeded the error after every other copy was corrected.
--
-- Evidence for the retraction, unchanged: ticket 828837 is Moises, decal C1184, and we hold 9,000
-- gallons for that truck against the 3,800 the county billed. Capacity is an internal fleet fact.
--
-- Also folded in, because the same comment already documents the state mapping and a reader will
-- look here: address, city, state, zip and county are NULL TOGETHER on the no-property case,
-- 14 of 700 rows as of 2026-08-26. That was asserted in the tests but stated in no document.

begin;

comment on view derm.v_lwt_monthly_rows is
  'One row per PICKUP ACTIVITY for the Miami-Dade LWT monthly filing, served by rpa-derm-monthly. '
  'in_scope = pickup county is Dade OR the ticket offloaded in Miami-Dade, evaluated PER ROW '
  'because 20 tickets mix counties. pickup_date is visits.visit_date and NEVER '
  'derm_manifests.service_date, a misnomer holding the dump date. '
  'gallons is always null by contract: the county bills MEASURED gallons per manifest off the '
  'invoice, and NOTHING on the form is computed from truck capacity or from the decal. '
  'truck_capacity_gallons is an internal fleet fact, served for sanity-checking a load only. '
  'truck_decal is the vehicle ACTIVE Miami-Dade permit number; null means we hold no decal and the '
  'caller must refuse the ticket rather than guess. '
  'truck_decals on the served payload is MANIFEST-grained while rows is filing-grained, so it can '
  'name a decal appearing on no row served; file from the row own truck_decal. '
  'state is mapped to USPS two-letter by an EXPLICIT list with unrecognised values passing through '
  'verbatim, so a non-Florida property can never be silently relabelled on a compliance form. '
  'address, city, state, zip and county are NULL TOGETHER on the no-property case (14 of 700 rows '
  'on 2026-08-26), never half-populated. '
  'client_name has typographic punctuation folded to ASCII; accented LETTERS are deliberately '
  'preserved because they are the correct spelling (Chateau, Espanola Way) and stripping them '
  'would misspell a regulator-facing document.';

-- Refuse to commit if the retracted claim survived, and prove the check can see the text at all.
do $$
declare c text;
begin
  select obj_description('derm.v_lwt_monthly_rows'::regclass, 'pg_class') into c;
  if c is null then
    raise exception 'the view has no comment at all; the COMMENT statement did not land';
  end if;
  if c ~* 'filed quantity is truck capacity' or c ~* 'resolved from the decal' then
    raise exception 'the retracted quantity claim is STILL in the view comment';
  end if;
  -- positive control: the check is reading real text, not an empty string
  if c !~* 'MEASURED gallons per manifest' then
    raise exception 'control failed: the corrected wording is not present either, so this check proves nothing';
  end if;
  raise notice 'view comment corrected and control passed';
end $$;

commit;
