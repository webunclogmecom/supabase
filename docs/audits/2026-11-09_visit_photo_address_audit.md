# Visit photo address audit, 2026-11-09 (Trello #183, JpIK7ORs)

**Ask.** Serena, reviewing Michael's visit for 111-YC (Nov 2), saw 2 photos stamped with a different street
address and asked whether the app or the upload caused it. Fred asked for that answer and an audit of other visits.

**Answer: neither, and no client-facing photo from a wrong site was found in 5+ weeks.**

## 1. The reported case (visit 6301, job 99900749)

| | |
|---|---|
| Nov 2, 02:21 to 02:42 ET | truck 1 parked **12 m** from the property (`fn_gps_stays`) |
| Nov 2, 02:33 | Michael takes 2 photos + 1 video (stamps "Index 3331/3332") |
| Nov 2, 02:38 | JobNote 271624342: **"No key in lock box"**, 3 files |
| Nov 2, 21:09 to 23:05 | truck back at the property, the work is done |
| Nov 3, 03:49 UTC | JobNote 271914269: "Job complete...", 22 files |

The two photos are proof of a failed first attempt the night before. The job has one visit that month, so the sync
put both notes on it, as the rule in `docs/reference/jobber-note-photo-attribution.md` section 4 says it should
(JobNote, within 2 days of the visit date). Both photos are classified `internal`, so the client never saw them.

**The street on the stamp is not evidence of a different site.** It is printed by the phone's timestamp-camera
app, which turns the phone's GPS into the nearest street address. The address printed on the two photos is the
side street next to the property. The same visit's own 22 photos carry six different street labels, one of them
about 4 km away. Jobber strips EXIF from attachments (all `exif_*` columns are null, the files are 810x1080), so
the burned-in stamp and the truck's GPS are the only location evidence we have.

## 2. The audit: every completed visit 2026-10-01 to 2026-11-08

Scope: 212 visits, 223 (visit, JobNote) pairs, 2,571 driver photos (`photos.source = 'jobber_note_sync'`).

**Notes, checked against the truck's GPS at the minute Jobber says each was posted.**
- 176 posted while the truck was at the property; 11 within a minute or two of leaving it.
- 34 posted elsewhere, nearly all explained: yard and dump visits (000-DH, 000-DP), Serena's office note on 004-BAO,
  trucks parked 160 to 190 m from a geocoded point, a crew whose truck is not the one on the visit (Grecia).
- 1 note with no Jobber time, 1 with no GPS stop.
- Only 5 visits hold notes posted 2 h or more apart; 111-YC is the only failed first attempt among them.

**Photos, by their burned-in stamp** (Windows OCR on every photo, then read by eye wherever it flagged).
- Stamp date: 1,475 readable. 29 flagged off the visit date; all 29 were checked by eye and are the visit's
  own night (the work runs past midnight) or OCR misreads. **0 real.**
- Stamp street against every stop visited that day (+/- 1 day): 1,048 match the visit's own property, 45 the same
  street further along, 641 match no stop (neighbouring-street drift), 42 named another stop's street.
- Those 42 were checked against the truck's GPS at the stamped minute. Five visits were at their own property
  (083-SHUL, 017-FIA, 015-FLA, 238-PV / 308-LOU which share a corner, 069-TCE); the rest were OCR splits.
  **Two are real, both `internal` tank-level photos:**
  - **043-MIL, visit 6620 (Nov 5):** files 3859 and 3860 were taken at 136-BB, 10 m from it, during 136-BB's visit,
    and Michael attached them to **both** jobs' notes (136-BB visit 6331 has the same two). The tank level at the
    end of one stop is the starting level of the next.
  - **012-DKC, visit 5906 (Oct 1):** one tank photo (file 1184) taken 2.8 km away, 15 minutes before the truck
    reached the site.

**Not covered:** 1,097 photos carry no readable stamp (paperwork, cameras with no stamp, OCR misses). They are
covered only at note level (where the note was posted), not photo by photo. Stamps were not geocoded, so the
641 "matches no stop" are judged by street name, not by distance.

## 3. Recommendations

1. **No code change.** The sync and the app behave as documented.
2. **Read the stamp's street as approximate.** To check where a photo was taken, compare its stamped time with the
   truck's GPS (`fn_gps_stays`), not its street name.
3. **Optional, Fred's call:** show each note's text and posted time above its photos in Admin Review. "No key in
   lock box, 2:38 AM" next to the two photos would have answered Serena's question on the page.

Working files (local only, not committed): the session scratchpad `c183/` folder (`notes_classified.json`,
`photo_audit.json`, `ocr_all.jsonl`).
