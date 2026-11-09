# Visit photo address audit, 2026-11-09 (Trello #183, JpIK7ORs)

**Ask.** Serena, reviewing Michael's visit for 111-YC (Nov 2), saw 2 photos stamped with a different street
address and asked whether the app or the upload caused it. Fred asked for that answer and an audit of other visits.

**Answer: neither. No Before / After / Extra photo was taken away from its property in 5+ weeks; 11 truck-tank photos on 5 visits were (section 2b).**

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

## 2b. Every photo measured against the property (added the same day, Fred: "maybe taken in wrong places as well")

Each stamped address was geocoded (Google Geocoding API) and measured against the visit's property pin; every
photo 250 m or more away was read by eye, re-geocoded, and checked against the truck's GPS at the stamped minute.
- Measured: 1,753 of 2,571 photos (1,121 exact matches, 274 garbled stamps transcribed by hand, 358 street-level
  matches within 250 m). Not measured: 818 photos whose stamp has no readable address (paperwork, cameras with no
  stamp, OCR misses).
- **Taken somewhere else: 11 photos on 5 visits, all pictures of the truck's tank, none Before / After / Extra:**

| visit | photos | where taken | distance from the property |
|---|---|---|---|
| 000-DP 2026-10-20 (disposal site) | 5 internal | our yard, before and after the dump | 51.6 km / 32.1 mi |
| 291-PER 2026-11-08 | 1, **unsorted** | 127-PC's stop (Dania Beach); same file on both jobs | 20.8 km / 12.9 mi |
| 058-SOH 2026-10-04 | 2 internal | 042-MT's stop | 8.8 km / 5.5 mi |
| 012-DKC 2026-10-01 | 1 internal | 1747 Alton Rd (132-PUM / 128-MF) | 2.8 km / 1.7 mi |
| 043-MIL 2026-11-05 | 2 internal | 136-BB's stop; same files on both jobs | 2.7 km / 1.7 mi |

  The pattern is one habit: the tank level photographed at the end of one stop is posted again as the starting
  level of the next job.
- Everything else far on paper was at the property by GPS: the camera's label was wrong (111-YC "6315 NW 2nd Ave",
  3.9 km off, truck 23 m from the property), the OCR was wrong, or the property is large.
- **Found on the way, a data issue: 289-PER's property pin is about 310 m off.** It equals Google's point for
  "17225 South Dixie Highway ste 100"; without "ste 100" Google puts it 310 m away, where the truck parks. So that
  visit's recorded time on site is 4 minutes (02:52 to 02:56) while the truck stood at the site 02:57 to 04:34.

## 3. Recommendations

1. **No code change.** The sync and the app behave as documented.
2. **Read the stamp's street as approximate.** To check where a photo was taken, compare its stamped time with the
   truck's GPS (`fn_gps_stays`), not its street name.
3. **Optional, Fred's call:** show each note's text and posted time above its photos in Admin Review. "No key in
   lock box, 2:38 AM" next to the two photos would have answered Serena's question on the page.

Working files (local only, not committed): the session scratchpad `c183/` folder (`notes_classified.json`,
`photo_audit.json`, `ocr_all.jsonl`).
