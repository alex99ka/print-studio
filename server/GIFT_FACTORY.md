# Gift Factory link

Gift Factory (`C:\claude projects\3d\3d manager`, private repo `alex99ka/gift-factory`) plans and prints
runs of 20–500 event gifts on the Bambu X2D. It talks to this server next to the Flag Maker, with its own key
and its own `/gf/` routes (`server/app/giftfactory.py`). Its `tests/check_crm_link.py` checks its side against
the contract below, so **the contract must not drift**: changing a route, a field name, a unit or a meaning is
`contract: 2`, served side by side with v1 until Gift Factory moves (tell Alex first).

The Flag Maker's `/fm/` routes, `flagmaker_key.json`, `FILES`, `SPIN_GRID` and its own contract check are
untouched; pairing one app never unpairs the other.

## Contract v1 (Gift Factory ↔ CRM)

**Pairing.** `POST /studio/giftfactory-key` (signed-in app user, like `/studio/flagmaker-key`) returns
`{"key": "<token>"}` once; the server stores only its SHA-256 in `giftfactory_key.json` (next to the Flag Maker's
file). Gift Factory sends it as header `X-Studio-Key` on every `/gf/` call; wrong or missing → **401**
("Gift Factory is not paired" / "Wrong Gift Factory key"). App UI: Settings → "חיבור Gift Factory" with the same
pair/copy flow as the Flag Maker's.

**Money** is integer agorot, VAT **not** included (the quote's VAT switch stays in the app, as today).
**Dates** are ISO `YYYY-MM-DD`; timestamps ISO 8601 UTC.

| Route | Body / answer | Notes |
|---|---|---|
| `GET /gf/requests` | `[{"id","title","customer","qty","status","latestVersion","updated","guests": {"names","gifts","uploadedAt"} or null}]` | Requests in status `draft`, `waiting`, `approved`, `printing`, newest first. |
| `POST /gf/requests/{rid}/versions` | multipart, same fields as the Flag Maker's upload (`preview`, `spin`, `spin_asm`, `model`, `recipe`, `note`) **plus** `names` (JPEG, the name proof sheet) | C2. Same `create_version(..., source="giftfactory")`. `names` is stored as `names.jpg`, added to `FILES` and `CLIENT_FILES`, watermarked like `preview.png` (grid 1). 409 when the request is locked (as now). |
| `PUT /gf/requests/{rid}/production` | JSON, see below | C1, C4, C6. Merged into `requests/{rid}.production`, `updatedAt` set. Any subset of the three parts may be sent. 404 unknown request. |
| `GET /gf/requests/{rid}/guests` | the uploaded file as it came (`.xlsx` or `.csv`, original name in `Content-Disposition`) | C3. 404 when there is none. |

`production` body (each part optional, every number an integer unless noted):

```json
{
  "contract": 1,
  "job": "Cart-Coin-20261029-1153",
  "quote": {
    "units": 105, "plates": 4, "printHours": 12.5, "finishDate": "2026-11-12",
    "unitCost": 193, "unitPrice": 271, "total": 28455,
    "breakdown": {"filament": 61, "power": 9, "wear": 14, "packaging": 50, "labour": 100, "failureMarginPct": 5}
  },
  "progress": {
    "platesDone": 1, "platesTotal": 4, "unitsOk": 25, "unitsTarget": 105, "failedUnits": 2,
    "finishDate": "2026-11-12", "lastEvent": "done"
  },
  "actualCost": {"filament": 5210, "power": 610, "wear": 1150, "packaging": 5250, "labour": 10500, "total": 22720}
}
```

`printHours` is a float; `lastEvent` is `done` | `failed` | `queued`. `breakdown` values are agorot per unit
except `failureMarginPct`.

**Push (C4).** When a PUT raises `progress.platesDone` or `progress.failedUnits` above the stored value, send
Alex one push through the existing `jobs.send_to(...)` helper: "Plate 2 of 4 done · <request title>" or
"2 units failed on <request title>". Nothing else pushes.

## As built (CRM 0.2.0, 29.10.2026)

Everything above holds. Where the text left a choice, the server does this:

- **Strict shapes.** A `PUT /production` body that is off contract is refused with **422**: `contract` other
  than 1, an unknown part or field, a part sent without all its fields, a number sent as text or as `2.0`
  where an integer is due, a negative count, a date not `YYYY-MM-DD`. `finishDate` may be `null` (no
  estimate yet). `printHours` may be an integer. `job` is optional.
- **Merge.** Each part sent replaces that part; parts not sent stay. The server sets
  `production.updatedAt`; the request's own `updatedAt` is **not** touched, so progress reports don't
  reorder Alex's request list.
- **Push.** Kind `production` (a switch in the app's notification settings), body = the customer's name.
  The failed count in the text is the rise since the last report. Both rising in one PUT gives one push:
  "Plate 2 of 4 done · 1 units failed on <request title>".
- **Versions.** `names` is optional; a `names` that is not a JPEG is refused (422), like any other file.
  The watermark is stamped square by square down a tall name check, so every page carries it.
- **Timestamps** (`updated`, `guests.uploadedAt`) are Python ISO 8601 with an offset, e.g.
  `2026-10-29T09:00:00.123456+00:00` (not `Z`), as `/fm/requests` has always sent them.
- **Guest file download.** `Content-Disposition: attachment; filename="guests.xlsx";
  filename*=UTF-8''<original name, percent-encoded>`.

### The portal's guest list (C3)

`GET /p/{token}/guest-template.xlsx`: one RTL sheet, header `שם / Name` | `כמות / Amount`, a grey note row
`כמות ריקה = עותק אחד · Empty amount = one copy`. `POST /p/{token}/requests/{rid}/guests` (field `file`) on a
request of that customer in `draft`, `waiting` or `approved` (else 404 / 409); `.xlsx` or `.csv` only (anything
else, `.xls` included → 400 "Save it as .xlsx or .csv"), ≤ 2 MB (413), ≤ 5000 rows (400). Rate-limited with
the comments. Parsed before it is kept, so a bad file never replaces a good one:

- first sheet; header = the first row with text; name column = header containing `name`/`שם`, amount column =
  `amount`/`כמות`/`qty`/`quantity`, else columns A and B; the grey note row and empty rows are skipped;
- empty amount = 1, `0` = not coming (skipped, reason `amount 0`), no name = skipped (reason `no name`);
- an amount that is not a whole number ≥ 0 (`two`, `1.5`, `-1`) refuses the **whole file**: 400
  `Row 7: the amount "two" is not a whole number`;
- CSV: UTF-8 (with or without BOM), else Windows-1255;
- answer `{"names": n, "gifts": total copies, "skipped": [[row, reason], ...]}`; rows are the spreadsheet's
  own row numbers.

Stored as `DATA_DIR/guests/{rid}/guests.xlsx|csv` (replacing the previous one; deleted with the request) and
`requests/{rid}.guests = {names, gifts, fileName, uploadedAt}`. One push (kind `client`): "Guest list from
<customer>: <gifts> gifts". Signed-in app: `GET /studio/requests/{rid}/guests`.

Differences from Gift Factory's `app/guests.py`, none of which changes how an accepted file imports there:
Gift Factory skips a row with a bad amount where the portal refuses the file, and reads `1.5` as 1.

**Visible to the client** on the portal, and nothing else from Gift Factory: the name check picture
(watermarked), their own guest summary (names, gifts, day), and while `approved`/`printing` one line from
`progress`: units OK of target and the finish day. No costs, prices, plate details or job names.

Note: the portal lists a request only once a version of it is published, so a fresh draft (nothing published)
can't take a guest list yet.
