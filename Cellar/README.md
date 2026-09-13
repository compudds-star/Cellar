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

## Adding online valuation & pricing later (no UI changes)

1. Stand up a small proxy on your Oracle host (holds the Wine-Searcher / retailer
   API key, caches responses, rate-limits per device). The app never sees the key.
2. Implement the protocols against it:
   ```swift
   struct WineSearcherValuationService: ValuationService {
       func estimate(for wine: Wine) async throws -> ValuationResult? { /* call your proxy */ }
   }
   struct ProxyPurchaseService: PurchaseService {
       func offers(for wine: Wine) async throws -> [MerchantOffer] { /* call your proxy */ }
   }
   ```
3. Swap the instances in `WhereToBuyView` / wherever you refresh valuations, and
   persist results as `ValuationSnapshot` / `PurchaseOption` rows. Done.

**Security notes** (per your standing preference to check as you build):
- API keys live on the proxy, never in the bundle or `Info.plist`.
- All traffic is HTTPS; pin if you want, but at minimum validate the host.
- The proxy rate-limits per install token so a leaked build can't run up your
  API bill.
- Cellar data is on-device only (`NSFileProtectionComplete`); nothing leaves the
  phone except the wine identity you send to price it.

---

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
