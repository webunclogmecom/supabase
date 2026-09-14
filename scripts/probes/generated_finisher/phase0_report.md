# Phase 0: the layout-guided matcher over the generated-sheet corpus

Generated 2026-09-14T04:05:12.445Z by phase0_corpus.mjs. 33 pages, 33 with a readable JPEG. Nothing was written.

Template prior (stamp midpoints): 25.84 / 33.76 / 41.1 / 48.145 / 55.925 / 64.155
Calibrated prior (mean over 16 MATCH pages): 25.062 / 33.431 / 40.218 / 47.481 / 55.38 / 63.247
Tolerances to pin: match 0.85 (worst residual 0.59), gap 0.85 (worst 0.56), clear 0.5 (smallest stamp clearance 1.464), search 2.5

Verdicts: MATCH = every band edge and both extents within 0.35pp of what a person accepted; RULES_ONLY = the six boundaries are the admitted printed rules but the saved bands or extent differ (read why: a templated extent, a hand-set band); MISMATCH = different geometry, must be explained or the matcher does not ship; REFUSED = the matcher declined, a person says whether the refusal is right; INELIGIBLE = fn_generated_page_cards refused the page (multi-row client, card not on the printed list, ...), the matcher result is shown for information only.

## Pass 2 (calibrated prior)

| folder | page | verdict | result | ineligible because |
|---|---|---|---|---|
| ticket-310429 | 1 | RULES_ONLY | shift 0.982; band 0.067 extent 0.473 rules 0.067 |  |
| ticket-310429 | 2 | MATCH | shift 0.67; band 0.134 extent 0.336 rules 0.134 |  |
| ticket-310590 | 1 | MATCH | shift 0.082; band 0.091 extent 0.137 rules 0.091 |  |
| ticket-310590 | 2 | MATCH | shift 0.211; band 0.155 extent 0.155 rules 0.052 |  |
| ticket-310607 | 1 | RULES_ONLY | shift -0.659; band 0.189 extent 0.422 rules 0.126 |  |
| ticket-311045 | 1 | RULES_ONLY | shift -0.169; band - extent 0.59 rules 0.043 |  |
| ticket-311780 | 1 | MATCH | shift 0.425; band 0.242 extent 0.242 rules 0.484 |  |
| ticket-311780 | 2 | MATCH | shift 0.388; band 0.163 extent 0.081 rules 0.082 |  |
| ticket-312433 | 1 | INELIGIBLE_AND_REFUSED | A stamp sits on the line between two rows. Place it again. | A client on this page is printed on several rows. Give it one card per permit and place each stamp on its own row, then measure the page with Draw the bands. |
| ticket-312433 | 2 | MATCH | shift -0.274; band 0.183 extent 0.027 rules 0.027 |  |
| ticket-312500 | 1 | MATCH | shift -0.959; band 0.064 extent 0.063 rules 0.064 |  |
| ticket-831325 | 1 | REFUSED | The printed rows could not be found on this scan. |  |
| ticket-831938 | 1 | RULES_ONLY | shift 0.046; band 0.137 extent 1.217 rules 0.069 |  |
| ticket-831938 | 2 | RULES_ONLY | shift 0.134; band 0.071 extent 1.057 rules 0.141 |  |
| ticket-832194 | 1 | INELIGIBLE_BUT_MATCHED | shift -0.06; band 0.119 extent 1.172 rules 8.663 | A client on this page is printed on several rows. Give it one card per permit and place each stamp on its own row, then measure the page with Draw the bands. |
| ticket-832194 | 2 | INELIGIBLE_AND_REFUSED | A stamp sits on the line between two rows. Place it again. | A client on this page is printed on a different page of this sheet. A person needs to check this page in Draw the bands. |
| ticket-832487 | 1 | MATCH | shift -0.221; band 0.161 extent 0.161 rules 0.242 |  |
| ticket-832487 | 2 | MATCH | shift -0.624; band 0.161 extent 0.161 rules 0.081 |  |
| ticket-833049 | 1 | INELIGIBLE_AND_REFUSED | A printed line between two rows is not visible on this scan. | A client on this page is printed on a different page of this sheet. A person needs to check this page in Draw the bands. |
| ticket-833049 | 2 | INELIGIBLE_AND_REFUSED | A printed line between two rows is not visible on this scan. | A client on this page is printed on a different page of this sheet. A person needs to check this page in Draw the bands. |
| ticket-833395 | 1 | INELIGIBLE_BUT_MATCHED | shift -0.272; band 14.572 extent 0.069 rules 0.069 | A client on this page is printed on several rows. Give it one card per permit and place each stamp on its own row, then measure the page with Draw the bands. |
| ticket-833813 | 1 | MATCH | shift 0.693; band 0.088 extent 0.088 rules 0.088 |  |
| ticket-833813 | 2 | MATCH | shift -0.917; band 0.089 extent 0.089 rules 0.089 |  |
| ticket-834287 | 1 | MATCH | shift 0.483; band 0.063 extent 0.063 rules 0.063 |  |
| ticket-834433 | 1 | MATCH | shift -0.686; band 0.065 extent 0.13 rules 0.13 |  |
| ticket-834742 | 1 | MISMATCH | shift 0.042; band 0.368 extent 0.32 rules 0.368 |  |
| ticket-834742 | 2 | MATCH | shift 0.169; band 0.214 extent 0.214 rules 0.214 |  |
| ticket-834986 | 1 | INELIGIBLE_AND_REFUSED | A printed line between two rows is not visible on this scan. | A client on this page is not on the printed list of this sheet, so its row cannot be found automatically. A person needs to check this page in Draw the bands. |
| ticket-834986 | 2 | INELIGIBLE_BUT_MATCHED | shift 0.29; band - extent 0.126 rules 0.153 | A client on this page is not on the printed list of this sheet, so its row cannot be found automatically. A person needs to check this page in Draw the bands. |
| ticket-835076 | 1 | MATCH | shift 0.788; band 0.044 extent 0.044 rules 0.044 |  |
| ticket-835076 | 2 | MATCH | shift 0.342; band 0 extent 0 rules 0 |  |
| ticket-835309 | 1 | MATCH | shift 0.517; band 0.139 extent 0.09 rules 0.258 |  |
| ticket-835309 | 2 | MATCH | shift -0.922; band 0.158 extent 0.116 rules 0.158 |  |

## Pass 1 (template prior)

| folder | page | verdict | result | ineligible because |
|---|---|---|---|---|
| ticket-310429 | 1 | RULES_ONLY | shift 0.373; band 0.067 extent 0.473 rules 0.067 |  |
| ticket-310429 | 2 | REFUSED | A printed line between two rows is not visible on this scan. |  |
| ticket-310590 | 1 | MATCH | shift -0.584; band 0.091 extent 0.137 rules 0.091 |  |
| ticket-310590 | 2 | MATCH | shift -0.46; band 0.155 extent 0.155 rules 0.052 |  |
| ticket-310607 | 1 | REFUSED | A printed line between two rows is not visible on this scan. |  |
| ticket-311045 | 1 | RULES_ONLY | shift -0.848; band - extent 0.59 rules 0.043 |  |
| ticket-311780 | 1 | MATCH | shift -0.164; band 0.242 extent 0.242 rules 0.484 |  |
| ticket-311780 | 2 | MATCH | shift -0.217; band 0.162 extent 0.081 rules 0.243 |  |
| ticket-312433 | 1 | INELIGIBLE_AND_REFUSED | A stamp sits on the line between two rows. Place it again. | A client on this page is printed on several rows. Give it one card per permit and place each stamp on its own row, then measure the page with Draw the bands. |
| ticket-312433 | 2 | REFUSED | A printed line between two rows is not visible on this scan. |  |
| ticket-312500 | 1 | MATCH | shift -1.443; band 0.064 extent 0.063 rules 0.064 |  |
| ticket-831325 | 1 | REFUSED | The printed rows could not be found on this scan. |  |
| ticket-831938 | 1 | RULES_ONLY | shift -0.688; band 0.137 extent 1.217 rules 0.069 |  |
| ticket-831938 | 2 | RULES_ONLY | shift -0.546; band 0.071 extent 1.057 rules 0.141 |  |
| ticket-832194 | 1 | INELIGIBLE_BUT_MATCHED | shift -0.659; band 0.119 extent 1.172 rules 8.663 | A client on this page is printed on several rows. Give it one card per permit and place each stamp on its own row, then measure the page with Draw the bands. |
| ticket-832194 | 2 | INELIGIBLE_AND_REFUSED | A stamp sits on the line between two rows. Place it again. | A client on this page is printed on a different page of this sheet. A person needs to check this page in Draw the bands. |
| ticket-832487 | 1 | MATCH | shift -0.792; band 0.161 extent 0.161 rules 0.242 |  |
| ticket-832487 | 2 | MATCH | shift -1.195; band 0.161 extent 0.161 rules 0.081 |  |
| ticket-833049 | 1 | INELIGIBLE_AND_REFUSED | A printed line between two rows is not visible on this scan. | A client on this page is printed on a different page of this sheet. A person needs to check this page in Draw the bands. |
| ticket-833049 | 2 | INELIGIBLE_AND_REFUSED | A printed line between two rows is not visible on this scan. | A client on this page is printed on a different page of this sheet. A person needs to check this page in Draw the bands. |
| ticket-833395 | 1 | INELIGIBLE_AND_REFUSED | A printed line between two rows is not visible on this scan. | A client on this page is printed on several rows. Give it one card per permit and place each stamp on its own row, then measure the page with Draw the bands. |
| ticket-833813 | 1 | MATCH | shift -0.065; band 0.088 extent 0.088 rules 0.088 |  |
| ticket-833813 | 2 | MATCH | shift -1.452; band 0.089 extent 0.089 rules 0.089 |  |
| ticket-834287 | 1 | MATCH | shift -0.217; band 0.063 extent 0.063 rules 0.063 |  |
| ticket-834433 | 1 | MATCH | shift -1.3; band 0.065 extent 0.13 rules 0.13 |  |
| ticket-834742 | 1 | REFUSED | A printed line between two rows is not visible on this scan. |  |
| ticket-834742 | 2 | MATCH | shift -0.461; band 0.214 extent 0.214 rules 0.214 |  |
| ticket-834986 | 1 | INELIGIBLE_AND_REFUSED | A printed line between two rows is not visible on this scan. | A client on this page is not on the printed list of this sheet, so its row cannot be found automatically. A person needs to check this page in Draw the bands. |
| ticket-834986 | 2 | INELIGIBLE_BUT_MATCHED | shift -0.335; band - extent 0.126 rules 0.153 | A client on this page is not on the printed list of this sheet, so its row cannot be found automatically. A person needs to check this page in Draw the bands. |
| ticket-835076 | 1 | MATCH | shift 0.085; band 0.044 extent 0.044 rules 0.044 |  |
| ticket-835076 | 2 | MATCH | shift -0.335; band 0 extent 0 rules 0 |  |
| ticket-835309 | 1 | MATCH | shift -0.143; band 0.139 extent 0.09 rules 0.258 |  |
| ticket-835309 | 2 | MATCH | shift -1.445; band 0.158 extent 0.116 rules 0.158 |  |

## Counts

- pass 2 MATCH: 18
- pass 2 RULES_ONLY: 5
- pass 2 MISMATCH: 1
- pass 2 REFUSED: 1
- pass 2 INELIGIBLE_BUT_MATCHED: 3
- pass 2 INELIGIBLE_AND_REFUSED: 5

## Sign-off

Read by the Supabase session on 2026-09-14 against the scans (cached in img/) and the served
geometry. Every row that is not MATCH, with the reason:

| folder | page | verdict | reading |
|---|---|---|---|
| ticket-310429 | 1 | RULES_ONLY | Bands agree within 0.067. The extent 25.8 / 64.4 is the value TEMPLATED on 2026-08-03; the printed roster is 26.273 to 64.142, so the extent is 0.47 wider at the top and 0.26 wider at the bottom. Wider is the safe direction (more black). Matcher right; no action. |
| ticket-310607 | 1 | RULES_ONLY | Bands within 0.189. Extent 23.7 / 63.6 was fitted by hand on 2026-08-20; the roster is 23.834 to 63.178, so it is wider by 0.13 and 0.42. Safe direction. Matcher right; no action. |
| ticket-311045 | 1 | RULES_ONLY | The page is still on DERIVED bands (the 2026-08-20 "1.60pp neighbour exposure" group that needed a person), so there are no accepted bands to compare. The six boundaries agree with the page's own admitted rules within 0.043, and the extent 24.85 / 63.44 is wider than the roster (25.276 to 62.85). Matcher right. This page is one the finisher would fix if it were open; it is completed and serving, so it needs a person in Draw the bands (the lines are already drawn for them). |
| ticket-312433 | 1 | INELIGIBLE_AND_REFUSED | 009-CN Casa Neos is printed on three rows and holds three cards. A multi-row client is refused by design (the card-to-row mapping goes through the manifest, which names the FIRST row for all three cards, so the matcher then sees three stamps on one row). A person measured it on 2026-08-28. Correct refusal. |
| ticket-831325 | 1 | REFUSED | The dark scan (896x724, roster median 210-216) where the detector finds only four boundaries; bands are still derived and the extent is templated. "The printed rows could not be found on this scan" is the true state. Correct refusal; a person owns this page (known since 2026-08-20). |
| ticket-831938 | 1 and 2 | RULES_ONLY | Bands within 0.137. Both extents end at 64.4, the 2026-08-03 templated bottom, while the last printed line is 63.18 / 63.34: wider by 1.2 and 1.06 at the bottom, safe direction. Tops agree within 0.07. Matcher right; no action. |
| ticket-832194 | 1 | INELIGIBLE_BUT_MATCHED | 043-MIL is printed on two rows (5 and 6, straddling the page break) and holds two cards, one per page; a multi-row client is refused by design. The matcher's six lines match the bands within 0.119 and the hand-set extent 24.4 / 64.7 is wider (safe). The "rules 8.663" figure is the classifier's phase error on this page: it labelled the true top boundary (24.486) a divider, so it is absent from the admitted boundary list; the matcher picked the printed line the classifier mislabelled. |
| ticket-832194 | 2 | INELIGIBLE_AND_REFUSED | Same client: its second card sits on page 2 while the manifest's printed row resolves to page 1, so the page-card reader refuses ("printed on a different page"). Correct refusal for the multi-permit shape; a person measured it. |
| ticket-833049 | 1 and 2 | INELIGIBLE_AND_REFUSED | The frozen folder: sheet 1089 is linked but the scans are the handwritten pads 338 and 387 (six slots, 5.5pp pitch), stored transposed. Refused twice over, independently: the page-card reader finds every card printed on the other page, and the matcher cannot find the printed rows. Exactly what the CHECK constraint on this folder already says. Correct. |
| ticket-833395 | 1 | INELIGIBLE_BUT_MATCHED | 242-WYN is printed on three rows and holds ONE card (the known un-split folder). Refused by design. The six lines match the extent within 0.069; the 14.6 band delta is that one card's accepted three-slot band against a one-slot band, as expected. Correct. |
| ticket-834742 | 1 | MISMATCH | The one row over the 0.35 line, by 0.018. The scan is 696x532, so one percent of the page is five pixels and 0.35pp is under two. On a line that blurry the Node detector and the browser detector (whose peaks the person confirmed on 2026-09-03) place the SAME printed line 1 to 2 pixels apart, in both directions (e.g. 33.647 vs 33.310, 55.639 vs 56.007), and the crop img/834742_p1_doubles.png shows single lines with nothing between the two placements. Both sets are on the printed rules; neither reaches text. Explained by resolution, not a matcher defect; no action. |
| ticket-834986 | 1 | INELIGIBLE_AND_REFUSED | Page 1 is a handwritten six-slot pad (3168x2444), and three of its four cards belong to manifests not linked to sheet 1079. Refused twice over. Correct. |
| ticket-834986 | 2 | INELIGIBLE_BUT_MATCHED | Page 2 IS the generated sheet (pitch matches, extent within 0.126, rules within 0.153), but only 214-MYK's manifest is linked to sheet 1079, so the other cards have no printed row and the page is refused. A person measured it on 2026-09-09 (Mila's two permits). Note: the person's second line sits at 33.706 with run 0.108 in the browser detector; the Node detector reads the same line at 33.859 with run 0.987. Correct refusal for the linking reason. |

**Calibration read.** The calibrated prior is the mean of the six printed boundaries over the 16
pages the template prior matched: 25.062 / 33.431 / 40.218 / 47.481 / 55.38 / 63.247 (gaps 8.37 /
6.79 / 7.26 / 7.90 / 7.87; the form's first slot is taller and its second shorter than the
stamp-midpoint template assumed, which is why 835076 page 2 sat 0.73 from the template). The worst
residual after calibration is 0.59 (ticket-310607 p1, a photograph whose roster is 1.2pp taller
than average: a scale difference, symmetric at the two ends) and the worst slot-gap deviation
0.56, so the tolerances to pin are **match 0.85, gap 0.85** (worst value plus 0.25, rounded up to
0.05), **clear 0.5** (the smallest stamp clearance seen is 1.46), search 2.5. A mid-slot divider is
never nearer than 2pp to a boundary target, so 0.85 cannot reach one.

**Fred's decision:**

- [x] Go: pin the calibrated prior and the tolerances above, and ship the finisher (Tasks 4 to 8 of the plan). Fred, 2026-09-14: "go, pin those numbers and ship it".
