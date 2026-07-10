-- 2026-07-10_wwtp_receipt_class_gate.sql
-- White-form redaction follow-up RESOLVED AS CLASSIFICATION (Fred: "go ahead with the white-form redaction"):
-- ground truth showed derm_manifest_url is NOT the FOG roster form — it is the per-load DISPOSAL RECEIPT
-- (SDWWTP / Broward septage / Black Point scale tickets: hauler, gallons, price, ticket#; NO customer
-- roster). An 8-agent vision fleet (wf_a8b4eae6) READ all 97 distinct images covering all 530 live
-- manifests: 97/97 = receipt, 0 rosters, 0 upload swaps. The receipt is the same doc client emails
-- already attach -> safe to serve raw. GATE: customer.work_orders.wwtp_receipt_url now serves the doc
-- ONLY when its URL is classified receipt in derm.receipt_doc_class (URL-keyed: group siblings inherit
-- the same URL -> auto-covered; genuinely NEW uploads stay hidden = "Document coming soon" until a
-- classification pass adds them — periodic task, see zero-runs note). ADR-010: ops/classification
-- metadata table, audit opt-out (machine-written, no business data).
BEGIN;
CREATE TABLE IF NOT EXISTS derm.receipt_doc_class (
  url text PRIMARY KEY,
  class text NOT NULL,
  note text,
  classified_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE derm.receipt_doc_class ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON derm.receipt_doc_class FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON derm.receipt_doc_class TO service_role;
INSERT INTO derm.receipt_doc_class (url, class, note) VALUES
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/100/manifest.jpg', 'receipt', 'SDWWTP ticket 818051, 3800 gal, 2-25-26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/1032/manifest.jpg', 'receipt', 'SDWWTP ticket 824713, 3800 gal, 5/17/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/104/manifest.jpg', 'receipt', 'SDWWTP ticket 823726, 3800 gal, 5/6/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/1043/manifest.jpg', 'receipt', 'SDWWTP ticket 824273, 3800 gal, 5/12/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/1044/manifest.jpg', 'receipt', 'SDWWTP ticket 824949, 3800 gal, 5/20/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/106/manifest.jpg', 'receipt', 'SDWWTP ticket 444849, 3800 gal, 3-4-26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/1071/manifest.jpg', 'receipt', 'SDWWTP ticket 825450, 3800 gal, 5/25/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/108/manifest.jpg', 'receipt', 'Broward septage receipt ticket 302279, 1700 gal'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/112/manifest.jpg', 'receipt', 'SDWWTP ticket 821593, 3800 gal, 4/16/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/113/manifest.jpg', 'receipt', 'Broward septage receipt ticket 298064, 1700 gal'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/116/manifest.jpg', 'receipt', 'Broward septage receipt ticket 294999, 1700 gal'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/12/manifest.jpg', 'receipt', 'SDWWTP ticket 817533, 2000 gal, 2-19-26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/13/manifest.jpg', 'receipt', 'SDWWTP ticket 821472, 3800 gal, 4/14/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/14/manifest.jpg', 'receipt', 'SDWWTP disposal ticket 815833, 2000 gal, 2/4/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/142/manifest.jpg', 'receipt', 'SDWWTP disposal ticket 816708, 2000 gal, 2/12/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/153/manifest.jpg', 'receipt', 'SDWWTP disposal ticket 445331, 3800 gal, 3/9/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/157/manifest.jpg', 'receipt', 'SDWWTP disposal ticket 816714, 2000 gal, 2/12/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/166/manifest.jpg', 'receipt', 'SDWWTP disposal ticket 822050, 3800 gal, 4/21/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/168/manifest.jpg', 'receipt', 'SDWWTP disposal ticket 818819, 3800 gal, 3/17/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/174/manifest.jpg', 'receipt', 'SDWWTP disposal ticket 821239, 3800 gal, 4/12/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/180/manifest.jpg', 'receipt', 'SDWWTP disposal ticket 813222, 2000 gal, 1/9/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/181/manifest.jpg', 'receipt', 'SDWWTP disposal ticket 816321, 2000 gal, 2/9/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/19/manifest.jpg', 'receipt', 'SDWWTP disposal ticket 813215, 2000 gal, 1/8/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/191/manifest.jpg', 'receipt', 'SDWWTP disposal ticket 820377, 3800 gal, 3/31/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/196/manifest.jpg', 'receipt', 'SDWWTP disposal ticket 817889, 2000 gal, 2/24/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/20/manifest.jpg', 'receipt', 'SDWWTP disposal ticket 812743, 2000 gal, 1/5/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/204/manifest.jpg', 'receipt', 'SDWWTP ticket 813788, 2000 gal, 1/15/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/212/manifest.jpg', 'receipt', 'Broward septage receipt 305031, 1700 gal, 5/14/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/227/manifest.jpg', 'receipt', 'SDWWTP ticket 821911, 3800 gal, 4/19/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/23/manifest.jpg', 'receipt', 'SDWWTP ticket 820615, 3800 gal, 4/2/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/230/manifest.jpg', 'receipt', 'SDWWTP ticket 813912, 2000 gal, 1/15/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/235/manifest.jpg', 'receipt', 'SDWWTP ticket 818188, 3800 gal, 2/26/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/24/manifest.jpg', 'receipt', 'SDWWTP ticket 821038, 3800 gal, 4/9/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/261/manifest.jpg', 'receipt', 'SDWWTP ticket 820810, 3800 gal, 4/7/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/267/manifest.jpg', 'receipt', 'Broward septage receipt 296524, 1700 gal, 1/23/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/29/manifest.jpg', 'receipt', 'SDWWTP ticket 812980, 2000 gal, 1/6/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/293/manifest.jpg', 'receipt', 'SDWWTP ticket 815951, 2000 gal, 2/5/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/300/manifest.jpg', 'receipt', 'SDWWTP ticket 815710, 2000 gal, 2/3/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/308/manifest.jpg', 'receipt', 'SDWWTP ticket 815064, 2000 gal, 1/28/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/315/manifest.jpg', 'receipt', 'SDWWTP ticket 816562, 2000 gal, $188, 2/10/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/337/manifest.jpg', 'receipt', 'SDWWTP ticket 814464, 2000 gal FOG, 1/22/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/350/manifest.jpg', 'receipt', 'SDWWTP ticket 820497, 3800 gal, $357.20, 4/1/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/351/manifest.jpg', 'receipt', 'Black Point ticket 000388, 3800 gal, 3/15/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/353/manifest.jpg', 'receipt', 'SDWWTP ticket 814459, 2000 gal, 1/21/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/37/manifest.jpg', 'receipt', 'SDWWTP ticket 814338, 2000 gal, 1/21/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/388/manifest.jpg', 'receipt', 'SDWWTP ticket 817415, 3800 gal, 2/18/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/42/manifest.jpg', 'receipt', 'SDWWTP ticket 820072, 2000 gal, 3/31/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/424/manifest.jpg', 'receipt', 'Black Point ticket 000195, 3800 gal, 3/12/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/43/manifest.jpg', 'receipt', 'SDWWTP ticket 815375, truck clean-out $50, 1/30/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/435/manifest.jpg', 'receipt', 'Black Point ticket 0000068, 3800 gal, 3/11/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/483/manifest.jpg', 'receipt', 'SDWWTP ticket 814219, 2000 gal, 1/19/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/488/manifest.jpg', 'receipt', 'SDWWTP ticket, 2000 gal, $188, date cropped'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/492/manifest.jpg', 'receipt', 'SDWWTP ticket 816845, 2000 gal, 2/13/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/50/manifest.jpg', 'receipt', 'SDWWTP ticket 822415, 3800 gal, 4/23/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/506/manifest.jpg', 'receipt', 'SDWWTP ticket 812982, 2000 gal, 1/7/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/51/manifest.jpg', 'receipt', 'SDWWTP ticket 821351, 3800 gal, 4/13/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/52/manifest.jpg', 'receipt', 'SDWWTP ticket 822919, 3800 gal, 4/28/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/522/manifest.jpg', 'receipt', 'SDWWTP ticket 816437, 2000 gal, 2/10/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/532/manifest.jpg', 'receipt', 'SDWWTP ticket 819503, 3800 gal, 3/24/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/543/manifest.jpg', 'receipt', 'SDWWTP ticket 823174, 3800 gal, 4/30/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/557/manifest.jpg', 'receipt', 'SDWWTP ticket 816565, 2000 gal, 2/11/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/611/manifest.jpg', 'receipt', 'SDWWTP ticket 818723, 3800 gal, 3/3/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/650/manifest.jpg', 'receipt', 'SDWWTP ticket 814105, 2000 gal, 1/18/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/70/manifest.jpg', 'receipt', 'SDWWTP ticket 822621, 3800 gal, 4/27/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/77/manifest.jpg', 'receipt', 'SDWWTP ticket 815594, 2000 gal, 2/2/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/776/manifest.jpg', 'receipt', 'South District WWTP ticket 812737, 2000 gal'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/78/manifest.jpg', 'receipt', 'Broward septage receiving receipt, ticket 300373, 1700 gal'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/79/manifest.jpg', 'receipt', 'Broward septage receiving receipt, ticket 303478, 1700 gal'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/84/manifest.jpg', 'receipt', 'South District WWTP ticket 819643, 3800 gal'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/842/manifest.jpg', 'receipt', 'South District WWTP ticket 822175, 3800 gal'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/85/manifest.jpg', 'receipt', 'South District WWTP ticket 444980, 3800 gal'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/867/manifest.jpg', 'receipt', 'South District WWTP ticket 816705, 2000 gal'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/87/manifest.jpg', 'receipt', 'South District WWTP ticket 814340, 2000 gal'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/88/manifest.jpg', 'receipt', 'South District WWTP ticket 814222, 2000 gal'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/926/manifest.jpg', 'receipt', 'South District WWTP ticket 812859, 2000 gal'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/94/manifest.jpg', 'receipt', 'South District WWTP ticket 823469, 3800 gal'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/968/manifest.jpg', 'receipt', 'South District WWTP ticket 824026, 3800 gal'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/969/manifest.jpg', 'receipt', 'South District WWTP ticket 824533, 3800 gal'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/999/manifest.jpg', 'receipt', 'SDWWTP ticket 825167, 3800 gal, 5/21/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1158/manifest_1.jpg', 'receipt', 'SDWWTP ticket 825560, 3800 gal, 5/26/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1171/manifest_1.JPG', 'receipt', 'SDWWTP ticket 825906, 2000 gal, 5/29/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1173/manifest_1.JPG', 'receipt', 'SDWWTP ticket 826477, 3800 gal, 6/4/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1187/manifest_1.JPG', 'receipt', 'SDWWTP ticket 826661, 3800 gal, 6/8/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1192/manifest_1.JPG', 'receipt', 'SDWWTP ticket 825666, 3800 gal, 5/28/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1194/manifest_1.jpeg', 'receipt', 'Broward septage receipt ticket 306859, 1700 gal, 6/10/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1208/manifest_1.jpg', 'receipt', 'SDWWTP ticket 827172, 3800 gal, 6/12/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1218/manifest_1.JPG', 'receipt', 'SDWWTP ticket 827989, 3800 gal, 6/21/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1236/manifest_1_1782329744401.JPG', 'receipt', 'SDWWTP ticket 828200, 3800 gal, 6/23/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1241/manifest_1.JPG', 'receipt', 'SDWWTP ticket 828625, 3800 gal, 6/28/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1246/manifest_1.JPG', 'receipt', 'SDWWTP ticket, 3800 gal, 6/28/2026, Anthony Clark'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1252/manifest_1.JPG', 'receipt', 'SDWWTP ticket 828837, 3800 gal, 6/30/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1276/manifest_1.JPG', 'receipt', 'SDWWTP FOG disposal receipt, 3800 gal, 7/4/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1297/manifest_1.JPG', 'receipt', 'SDWWTP receipt no. 826114, 3800 gal, 6/1/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1299/manifest_1.JPG', 'receipt', 'SDWWTP receipt no. 829216, 3800 gal, 7/5/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1328/manifest_1.JPG', 'receipt', 'SDWWTP receipt no. 829322, 3800 gal, 7/6/26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1336/manifest_1.JPG', 'receipt', 'Broward septage receipt ticket 308684, 3840 gal'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1343/manifest_1.JPG', 'receipt', 'Broward septage receipt ticket 308792, 3840 gal')
ON CONFLICT (url) DO NOTHING;
COMMIT;

-- view repoint (gated restore):
CREATE OR REPLACE VIEW customer.work_orders AS
 SELECT v.public_id AS id,
    customer.uuid_from_bigint(v.client_id) AS client_id,
    v.visit_date,
        CASE
            WHEN v.start_at IS NOT NULL THEN to_char((v.start_at AT TIME ZONE 'America/New_York'::text), 'FMHH12:MI AM'::text)
            ELSE NULL::text
        END AS visit_time,
    COALESCE(( SELECT string_agg(e.full_name, ', '::text ORDER BY e.full_name) AS string_agg
           FROM visit_assignments va
             JOIN employees e ON e.id = va.employee_id
          WHERE va.visit_id = v.id), ( SELECT string_agg(e2.full_name, ', '::text ORDER BY e2.full_name) AS string_agg
           FROM visit_team vt
             JOIN employees e2 ON e2.id = vt.employee_id
          WHERE vt.visit_id = v.id)) AS driver,
    veh.name AS truck,
    veh.decal_number AS decal,
    COALESCE(v.manhole_count, NULLIF(prop.grease_trap_manhole_count, 0), NULLIF(( SELECT prim.grease_trap_manhole_count
           FROM properties prim
          WHERE prim.client_id = v.client_id AND prim.is_primary = true
         LIMIT 1), 0)) AS manholes,
    v.manhole_breakdown,
    v.ticket_number,
    v.trap_condition_notes AS trap_condition,
    row_number() OVER (PARTITION BY v.client_id, (EXTRACT(year FROM v.visit_date)) ORDER BY v.visit_date)::integer AS visit_num,
    ( SELECT
                CASE
                    WHEN sc.frequency_days IS NULL OR sc.frequency_days <= 0 THEN NULL::integer
                    ELSE GREATEST(1::numeric, round(365.0 / sc.frequency_days::numeric))::integer
                END AS "greatest"
           FROM service_configs sc
          WHERE sc.client_id = v.client_id AND sc.service_type = v.service_type
         LIMIT 1) AS visit_total,
    v.title AS notes,
    dm.white_manifest_number AS derm_manifest_number,
    rd.url AS derm_manifest_url,
    COALESCE(dm.wwtp_receipt_number, dm.white_manifest_number, dm.yellow_ticket_number) AS wwtp_receipt_number,
    CASE WHEN rc.class = 'receipt' THEN dm.derm_manifest_url END AS wwtp_receipt_url,
    dm.wwtp_ticket_number,
    v.created_at,
    COALESCE(v.completed_at, v.created_at) AS updated_at,
    COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) AS manifest_number,
        CASE
            WHEN dm.white_manifest_number IS NOT NULL THEN 'dade'::text
            WHEN dm.yellow_ticket_number IS NOT NULL THEN 'broward'::text
            ELSE NULL::text
        END AS manifest_jurisdiction,
    dm.id AS manifest_id,
    COALESCE(NULLIF(prop.sample_port_count, 0), NULLIF(( SELECT prim.sample_port_count
           FROM properties prim
          WHERE prim.client_id = v.client_id AND prim.is_primary = true
         LIMIT 1), 0)) AS sample_ports,
    ( SELECT df.name
           FROM disposal_facilities df
          WHERE df.id = dm.disposal_facility_id) AS disposal_facility,
    COALESCE(( SELECT array_agg(TRIM(BOTH FROM regexp_replace(li.name, '^\s*\d+\s*-\s*'::text, ''::text)) ORDER BY li.id) AS array_agg
           FROM line_items li
          WHERE li.visit_id = v.id AND li.name IS NOT NULL AND TRIM(BOTH FROM li.name) <> ''::text AND li.name !~* '(credit[ ]?card|fee|discount|surcharge|convenience|gratuity)'::text), ARRAY[]::text[]) AS services
   FROM visits v
     LEFT JOIN vehicles veh ON veh.id = v.vehicle_id
     LEFT JOIN properties prop ON prop.id = v.property_id
     LEFT JOIN LATERAL ( SELECT dm_inner.id,
            dm_inner.client_id,
            dm_inner.service_date,
            dm_inner.dump_ticket_date,
            dm_inner.white_manifest_number,
            dm_inner.yellow_ticket_number,
            dm_inner.sent_to_client,
            dm_inner.sent_to_city,
            dm_inner.created_at,
            dm_inner.updated_at,
            dm_inner.wwtp_receipt_number,
            dm_inner.wwtp_receipt_document_path,
            dm_inner.wwtp_ticket_number,
            dm_inner.disposal_facility_id,
            dm_inner.derm_manifest_url,
            dm_inner.derm_address_url,
            dm_inner.fog_manifest_url,
            dm_inner.gdo_id
           FROM derm_manifests dm_inner
             JOIN manifest_visits mv ON mv.manifest_id = dm_inner.id
          WHERE mv.visit_id = v.id AND dm_inner.deleted_at IS NULL
          ORDER BY dm_inner.service_date DESC NULLS LAST
         LIMIT 1) dm ON true
     LEFT JOIN derm.redacted_manifest_docs rd ON rd.manifest_id = dm.id AND rd.client_id = v.client_id
     LEFT JOIN derm.receipt_doc_class rc ON rc.url = dm.derm_manifest_url
  WHERE v.visit_status = 'completed'::text AND v.client_id IS NOT NULL AND COALESCE(v.derm_required, true) = true AND v.deleted_at IS NULL;
