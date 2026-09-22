# App Store review notes

Paste the block below into **App Store Connect → App Review Information → Notes**
when submitting. It exists because Cellar talks to a pricing server the developer
runs, and a reviewer who doesn't know that could mistake a capped or offline
lookup for a broken feature.

Before submitting, check that the server is reachable and that the caps are set
for review (Settings → tap the version line 5× → Server admin → per-device cap 10):

```bash
curl -s https://cellar.orangeeaglesa.com/health
```

---

```text
No account, login, or setup is required. The app works fully on first launch.

ONLINE PRICING
Cellar estimates bottle values through a pricing service the developer hosts. No
credentials are needed — the app is preconfigured and the service allows a limited
number of lookups per device. To see it: Cellar tab → + → type any wine (e.g.
producer "Opus One", vintage 2018) → Save. An estimated value appears on the wine
once the lookup returns (it can take up to ~30 seconds for a wine not already
cached). "Where to buy" on a wine's page shows merchant offers for the same wine.

If the daily/monthly lookup allowance is exhausted during testing, the app says so
plainly and everything else keeps working — please let us know rather than treating
it as a failure, and we will raise the limit immediately.

WORKS WITHOUT A NETWORK
Online pricing is optional. With it off (Settings → Pricing endpoint → clear the
field), the whole app still works: label scanning, the bundled 205,000-wine
identity database, manual valuations, collections, tasting notes, drink-window
reminders, CSV/PDF export.

PRIVACY
The cellar itself never leaves the device: wines, bottles, photos, notes and any
location use stay in an on-device store. A price lookup sends only the wine's name
and vintage plus a random per-install identifier, which the pricing service counts
against a usage limit. There is no analytics SDK and no third-party SDK of any kind.

CAMERA / PHOTOS / LOCATION
Camera and photo library are used only to read a wine label (on-device Vision OCR).
Location is requested only when you tap "Where to buy" → "Nearby stores", to find
wine shops near you; it is never stored or transmitted.

ATTRIBUTION
Wine identity data is the Liv-ex LWIN database, used under CC BY 4.0. The credit is
shown in the app on the LWIN match screen.
```
