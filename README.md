# Cellar — iOS wine cellar app

A native SwiftUI + SwiftData iPhone app: scan a bottle's label (or type the
name), keep a cellar database, total each wine's and the whole cellar's
estimated value, and find where to buy a bottle with directions to the store.

This is a **standalone Xcode project** that happens to live in a subdirectory
of the DOONY repo. It references nothing outside `Cellar/`. To split it into its
own repo: copy the `Cellar/` directory out and `git init`.

```
brew install xcodegen        # if you don't have it
cd Cellar
xcodegen generate            # produces Cellar.xcodeproj
open Cellar.xcodeproj
```

Set `DEVELOPMENT_TEAM` in `project.yml` (currently your DOONY team `24Q366W5BQ`)
and a real bundle id if `com.doony.cellar` is taken.

---

## Architecture at a glance

| Layer | Files | Notes |
|---|---|---|
| **Data model** | `Models/Wine.swift` | SwiftData `@Model`: `Wine` (label/vintage identity) → many `Bottle` (physical bottles) + `ValuationSnapshot` + `PurchaseOption`. |
| **Scanning** | `Scan/*` | VisionKit `DataScannerViewController` for live label OCR, `Vision` for still-photo fallback, `LabelParser` (pure) to turn text lines into structured fields. |
| **Valuation** | `Valuation/*` | `ValuationService` protocol + `ManualValuationService` (offline). `CellarStats` aggregates totals. |
| **Where to buy** | `Purchase/*` | `NearbyStores` (MapKit, works today) + `PurchaseService` protocol (online pricing, stubbed). |
| **UI** | `Views/*` | Cellar list, wine detail, add/scan flow, value dashboard, where-to-buy. |

The two things that cost money or carry legal weight — **online valuation** and
**online merchant pricing** — sit behind protocols (`ValuationService`,
`PurchaseService`) with offline no-op implementations wired in. The UI never
knows the difference, so you drop in a real backend later without touching a
view. **This is the key decision: ship offline-first, enrich later.**

---

## The features, and how each is built

### 1. Scan a label OR enter manually
`AddWineFlow` is one form. "Scan label" opens `ScanSheet` →
`DataScannerViewController` reads text off the label continuously into a
`ScanBuffer`; on capture, `LabelParser.parse(lines:)` extracts producer,
vintage, varietal, region/country, and guesses the wine type. The parsed fields
**pre-fill** the same form you'd fill by hand — scanning never blocks saving,
and every field stays editable.

`LabelParser` is deliberately a pure function (no camera, no I/O) so it's fully
unit-tested (`CellarTests/LabelParserTests.swift`).

**Reality check on label scanning:** on-device OCR reads the *text* well, but a
label is marketing art, not a structured record — producer vs. cuvée vs.
appellation is a heuristic guess. Three ways to make it better, cheapest first:
1. **OCR + heuristics (shipped).** Free, offline, ~good enough to pre-fill.
2. **Barcode/UPC path.** Add `.barcode()` to the scanner's data types and map
   UPC → wine via a lookup service. Most reliable *when* a barcode maps cleanly
   (many fine wines don't).
3. **Cloud label-recognition** (Vivino-style image match). Highest accuracy,
   but it's a paid/hosted classifier and a network dependency. Fits behind a
   `LabelRecognitionService` protocol exactly like valuation does.

### 2. Cellar database + value totals
`Wine` → `[Bottle]`. Each `Bottle` has a size (split → imperial); value scales
by `BottleSize.priceFactor` (a magnum ≈ 2× a 750 mL). Per-bottle value
precedence: **manual estimate → valuation snapshot → price paid → unknown.**

`CellarStats` sums in-stock bottles into `totalEstimatedValue`, per-type
breakdown, and a `hasUnvaluedBottles` flag so the dashboard can honestly show
the total as a **floor** when some bottles have no estimate — rather than
silently understating. Shown on the Value tab with a Swift Charts breakdown.

### 3. Where to buy + directions
`WhereToBuyView` has two sections:
- **Nearby stores (works today):** one-shot Core Location fix → `MKLocalSearch`
  for "wine store" → sorted by distance → tap for Apple Maps driving
  directions. No API key, no cost. This answers "where are the wine shops near
  me," which is the reliably-solvable version of the feature.
- **Online offers (stubbed):** `PurchaseService.offers(for:)` returns merchant
  name + price + URL. `NoRemotePurchaseService` returns none today.

**Reality check on "price + inventory for *this* bottle at *that* store":** that
data comes from aggregators (Wine-Searcher is the standard) or per-retailer
APIs. Wine-Searcher's API is paid and its terms prohibit scraping — so the
honest path is a licensed API called from **your own proxy** (Oracle Cloud host)
that holds the key and rate-limits, never from the app. That proxy is the
concrete `ValuationService`/`PurchaseService` you add next; see below.

---

## Online valuation & offers — built (Wine-Searcher / any provider)

`Valuation/RemoteValuationClient` implements both `ValuationService` and
`PurchaseService` against **one provider-agnostic JSON endpoint**, so the app
never encodes any single provider's schema. Your proxy (or a direct adapter)
maps Wine-Searcher / Apify / CellarTracker into this contract:

```
GET {baseURL}/valuation?lwin={lwin11}&q={producer name}&vintage={year}&currency=USD
→ { "average": 189.00, "min": 165.00, "max": 220.00, "currency": "USD",
    "offers": [ { "merchant": "…", "price": 175.00, "currency": "USD",
                  "url": "https://…", "address": "…",
                  "latitude": 41.0, "longitude": -73.7, "inStock": true } ] }
```

- `ValuationCoordinator` picks the remote service when configured, enforces a
  **7-day cache per wine** (a paid API is hit at most once per wine per week),
  and persists results as `ValuationSnapshot` + `PurchaseOption` rows.
- **Refresh price online** (wine detail) and **Refresh offers** (Where to buy)
  trigger it; offers render with an Open link and Directions when a store
  coordinate is present. Nearby-store search (MapKit) still works with no
  endpoint at all.

**Configure it** in Settings (gear icon):
- **Endpoint** (`baseURL`) — stored in UserDefaults, must be HTTPS. Point it at
  your Oracle-host proxy (recommended) or directly at a provider.
- **API key** — stored in the **Keychain** (device-only, `ThisDeviceOnly`),
  never in the bundle/`Info.plist`/logs; sent only as a `Bearer` header, never
  in the URL. Leave blank if your proxy holds the key.

**Security notes** (per your standing preference to check as you build):
- Key in Keychain, not the binary; HTTPS enforced (an `http://` endpoint is
  rejected as "not configured"); credential never in the query string.
- Recommended: proxy holds the real provider key and rate-limits per install so
  a leaked build can't run up your API bill.
- Cellar data is on-device only (`NSFileProtectionComplete`); nothing leaves the
  phone except the wine identity you send to price it.
- The 7-day TTL keeps your Wine-Searcher trial (100 free calls/day) or Apify
  per-wine (~2.5¢) cost negligible for a personal cellar.

---

## Wine identity — LWIN matching (free, built in)

`LWIN/*` snaps a scanned/typed wine to a canonical **Liv-ex Wine Identification
Number** (the "ISBN for wine"). It's free, needs no API approval, and gives you
a stable de-dup/identity key that a pricing API can later look the wine up by.

- `LWINDatabase` loads a CSV once and builds an inverted token index (scores only
  records sharing a token with the query, not all ~200k rows).
- `LWINMatcher` scores candidates by token recall + Jaccard, with small bonuses
  for matching region and a plausible vintage; returns ranked matches.
- In **Add wine**, "Find LWIN match" opens `LWINMatchView`; picking a result
  stores `Wine.lwin7` and backfills blank fields. `Wine.lwin11` composes
  wine + vintage (NV → Liv-ex's `1000`).

**Ships with a 20-wine sample** (`Cellar/Resources/lwin_sample.csv`) so the
feature works immediately. The sample's codes start at `9000001` and are
**illustrative, not authoritative** — replace them with the real database for
full coverage and correct codes:

1. Download the free LWIN database from Liv-ex (`liv-ex.com/lwin/` → LWIN
   database form; licensed **CC BY 4.0**). CSV or XLSX both work.
2. Convert it: `python3 scripts/import_lwin.py ~/Downloads/<file>`. This writes a
   trimmed `Cellar/Resources/LWIN.csv`: retired codes, spirits and cider (add
   `--include-spirits` to keep them), mixed/assortment cases and unused columns
   are removed; `TYPE` becomes Still / Sparkling / Fortified (Port) / …. Columns
   are matched by header name, so order doesn't matter.
3. `xcodegen generate` (first time, so the new file is bundled), then rebuild.
   `LWINDatabase` prefers `LWIN.csv` over the sample automatically.

The repo includes a converted copy (Liv-ex download of 2026-09-13, ~185k wines,
22 MB); re-run the script to refresh it. The LWIN match screen shows the Liv-ex
credit that CC BY 4.0 requires; keep it if you change that screen.

Matching indexes producer title + producer + wine (not the display name, whose
classification/appellation words dilute scores), also tries the producer alone
when a scan put a byline in the name, and the Add form only snaps automatically
when the best match is confident and clearly ahead of the runner-up.

Because the sample codes aren't authoritative, don't feed a sample-derived
`lwin7` to a pricing API as if it were real — swap in the Liv-ex file first.

## Common cellar-app features included / easy next

**Included:** scan or manual add, label image, multi-bottle inventory with
size/price/storage/status (in-stock/consumed/gifted/sold), per-wine and
whole-cellar valuation, search + type filter, value-by-type chart, nearby stores
+ directions, drink-by window fields.

**Easy next steps (models already support them):**
- **Drink-window alerts:** `Bottle.drinkFrom/drinkTo` are stored; add
  `UNUserNotificationCenter` reminders.
- **iCloud sync across devices:** flip `cloudKitDatabase: .automatic` in
  `CellarApp` and add the iCloud/CloudKit entitlement.
- **CSV/PDF export & backup:** mirror DOONY's `Export/` approach.
- **Tasting notes & ratings:** add fields to `Wine`/a `TastingNote` model.
- **Barcode add:** add `.barcode()` to `DataScannerViewController`'s data types.

---

## Tests
`CellarTests/LabelParserTests.swift` covers the pure parser and the valuation
aggregation (size scaling, paid-price fallback, unvalued flagging) — the logic
worth locking down. Run in Xcode (⌘U) or `xcodebuild test`.
