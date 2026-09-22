# App Store listing copy

Paste-ready text for App Store Connect. Limits are Apple's: subtitle 30
characters, promotional text 170, keywords 100 (the whole comma-separated
string), description 4000.

Promotional text and keywords can be changed any time without a new build.
The description and subtitle can only change with a new version.

---

## App name (30 max)

```
Vino Cellar
```

## Subtitle (30 max)

```
Your cellar, bottle by bottle
```

## Promotional text (170 max)

```
Scan a label and the bottle is in your cellar — with what it's worth, when to drink it, and what you thought of it. Everything stays on your iPhone.
```

## Keywords (100 max, commas, no spaces)

```
wine,bottle,collection,tasting,vintage,inventory,sommelier,winery,label,scanner,whisky,spirits,rack
```

Notes: "vino" and "cellar" are left out on purpose — Apple already indexes the
app name, so repeating them wastes characters. No competitor names: using another
app's trademark as a keyword invites rejection.

## Description (4000 max)

```
Vino Cellar keeps track of the wine you own — what it is, what it cost, what it's worth now, and when to open it.

Point the camera at a label and it reads the producer, name and vintage for you. Match it against a bundled database of more than 200,000 wines and spirits, and the bottle gets a proper identity rather than a typo. Then tell it how many you have, what you paid, and where they're stored.

WHAT IT'S WORTH
Give each wine an estimate, or let the app fetch one, and it totals your whole cellar. See what you paid against what it's worth now, and where the value sits by type — a quiet answer to "how much wine is in this house, exactly?"

DRINK IT AT THE RIGHT TIME
Set a drinking window and Vino Cellar reminds you when a bottle enters it. Bottles you've finished move to their own tab, keeping the tasting note and the rating, so you remember the ones worth buying again.

MORE THAN ONE PLACE
Collections keep the beach house separate from the rack in the basement, each with its own total.

YOUR NOTES, YOUR RATINGS
Dated tasting notes and a five-star rating per wine. A wishlist for the bottles you don't own yet — move one into the cellar the day you buy it.

TAKE IT WITH YOU
Export the lot as a CSV or a PDF summary whenever you like. It's your cellar; you can always get it out.

FINDING A BOTTLE
Optional online pricing can fetch estimates, critic scores and merchant offers, and show wine shops near you with directions. Fair-use limits apply. Turn it off and everything else still works.

BUILT TO STAY YOURS
No account. No sign-up. No analytics, no advertising, no tracking of any kind, and no third-party SDKs. Your cellar lives on your iPhone and is never uploaded — the only thing that ever leaves, and only if you ask for a price, is the name and vintage of the wine you're pricing.

iPhone, iOS 18 or later.

Wine identity data is the Liv-ex LWIN database, used under CC BY 4.0.
```

## What's New (for version 1.0)

```
First release.
```

---

## Content rights declaration

App Store Connect asks whether the app contains, shows or accesses third-party
content. The answer is **Yes**, and this is what that covers:

| Content | Basis |
|---|---|
| **LWIN wine identity database** (Liv-ex), bundled, ~205,000 wines and spirits | CC BY 4.0. The credit is shown in the app on the LWIN match screen. |
| **Apple Maps** search for nearby wine shops | Apple Developer Program Licence Agreement. |
| **Price estimates, critic scores and merchant offers** from the pricing service | Factual data points retrieved per request to answer the user's own query. Not stored or redistributed beyond the user's own device. |

**Label photographs are deliberately not used.** A wine's picture is one the user
scanned or chose; nothing remote is fetched or displayed. The app does not read a
provider image URL (`RemoteValuationClient` passes `imageURL: nil`, and the
thumbnail and detail views have no remote branch), and the proxy strips `image`
from every response, including cached ones written before that change. If you
ever switch to a licensed image source, that's the code to revisit.
