// Cellar pricing proxy
//
// Serves GET /valuation in the exact shape the Cellar iOS app expects, adapting
// a provider (Wine-Searcher / Apify / a built-in mock) behind it. The provider
// API key lives ONLY here (env var), never in the app. The app authenticates to
// this proxy with a separate bearer token (PROXY_TOKEN) so a leaked app build
// can be cut off by rotating the token without touching the provider key.
//
// Run behind nginx + Let's Encrypt for TLS; this process listens on localhost.
// See README.md for deployment.

import express from "express";

const {
  PORT = "8787",
  HOST = "127.0.0.1",
  PROVIDER = "mock",                 // mock | winesearcher | apify
  PROXY_TOKEN = "",                  // if set, the app must send it as a Bearer token
  WS_API_URL = "",                   // Wine-Searcher API base (from their docs)
  WS_API_KEY = "",                   // Wine-Searcher API key (secret)
  APIFY_TOKEN = "",                  // Apify token (secret)
  APIFY_ACTOR = "mrbridge~vivino-wine-data-scraper",
  CACHE_TTL_SECONDS = "604800",      // 7 days — matches the app's per-wine TTL
  RATE_LIMIT_PER_MIN = "60",
} = process.env;

const CACHE_TTL_MS = Number(CACHE_TTL_SECONDS) * 1000;
const RATE_LIMIT = Number(RATE_LIMIT_PER_MIN);

const app = express();
app.disable("x-powered-by");
app.set("trust proxy", 1); // behind nginx; use X-Forwarded-For for rate limiting

// ---- Auth: constant-time compare of the app's bearer token ------------------
import { timingSafeEqual } from "crypto";
function tokenOK(header) {
  if (!PROXY_TOKEN) return true; // no token configured → open (use only behind a private network)
  const m = /^Bearer\s+(.+)$/.exec(header || "");
  if (!m) return false;
  const a = Buffer.from(m[1]);
  const b = Buffer.from(PROXY_TOKEN);
  return a.length === b.length && timingSafeEqual(a, b);
}

// ---- Tiny in-memory rate limiter (per client IP, per minute) ----------------
const hits = new Map(); // ip -> { count, resetAt }
function rateLimited(ip) {
  const now = Date.now();
  const rec = hits.get(ip);
  if (!rec || now > rec.resetAt) {
    hits.set(ip, { count: 1, resetAt: now + 60_000 });
    return false;
  }
  rec.count += 1;
  return rec.count > RATE_LIMIT;
}

// ---- Tiny in-memory response cache ------------------------------------------
const cache = new Map(); // key -> { at, body }
function cacheGet(key) {
  const rec = cache.get(key);
  if (rec && Date.now() - rec.at < CACHE_TTL_MS) return rec.body;
  if (rec) cache.delete(key);
  return null;
}
function cacheSet(key, body) {
  cache.set(key, { at: Date.now(), body });
}

app.get("/health", (_req, res) => res.json({ ok: true, provider: PROVIDER }));

app.get("/valuation", async (req, res) => {
  const ip = req.ip || req.socket.remoteAddress || "unknown";
  if (rateLimited(ip)) return res.status(429).json({ error: "rate_limited" });
  if (!tokenOK(req.headers.authorization)) return res.status(401).json({ error: "unauthorized" });

  const lwin = String(req.query.lwin || "").trim();
  const q = String(req.query.q || "").trim();
  const vintage = String(req.query.vintage || "").trim();
  const currency = String(req.query.currency || "USD").trim().toUpperCase();
  if (!lwin && !q) return res.status(400).json({ error: "missing_query" });

  const cacheKey = JSON.stringify({ lwin, q, vintage, currency, PROVIDER });
  const cached = cacheGet(cacheKey);
  if (cached) return res.json(cached);

  try {
    const body = await lookup({ lwin, q, vintage, currency });
    cacheSet(cacheKey, body);
    res.json(body);
  } catch (err) {
    // Never leak the provider key or full upstream URL in errors/logs.
    console.error("lookup failed:", err?.message || "error");
    res.status(502).json({ error: "provider_error" });
  }
});

// ---- Provider dispatch ------------------------------------------------------
async function lookup(params) {
  switch (PROVIDER) {
    case "winesearcher": return await lookupWineSearcher(params);
    case "apify":        return await lookupApify(params);
    default:             return lookupMock(params);
  }
}

// The app's contract. Every adapter returns this shape.
function contract({ average = null, min = null, max = null, currency = "USD", score = null, image = null, offers = [], source = null }) {
  return { average, min, max, currency, score, image, offers, source };
}

// ---- Mock: deterministic fake data so the app works end-to-end today --------
function lookupMock({ q, lwin, currency }) {
  const seed = [...(q || lwin || "wine")].reduce((a, c) => a + c.charCodeAt(0), 0);
  const avg = 40 + (seed % 160);           // $40–$200
  const min = Math.round(avg * 0.85);
  const max = Math.round(avg * 1.2);
  const score = 86 + (seed % 12);          // 86–97 pts
  const merchants = ["Wine Library", "Total Wine", "K&L Wines", "Vivino Market"];
  const offers = merchants.map((m, i) => ({
    merchant: m,
    price: Math.round(min + i * ((max - min) / 3)),
    currency,
    url: "https://example.com/search?q=" + encodeURIComponent(q || lwin),
    address: i === 2 ? "123 Main St, White Plains, NY" : null,
    latitude: i === 2 ? 41.034 : null,
    longitude: i === 2 ? -73.763 : null,
    inStock: true,
  }));
  const image = "https://placehold.co/240x320.png?text=" + encodeURIComponent(q || lwin || "Wine");
  return contract({ average: avg, min, max, currency, score, image, offers, source: "mock" });
}

// ---- Wine-Searcher adapter --------------------------------------------------
// NOTE: confirm the exact request params and response field names against your
// Wine-Searcher API docs when you get a key, and adjust the mapping below.
// The key is sent to Wine-Searcher only, from this server.
async function lookupWineSearcher({ q, lwin, vintage, currency }) {
  if (!WS_API_URL || !WS_API_KEY) throw new Error("winesearcher not configured");
  const url = new URL(WS_API_URL);
  url.searchParams.set("api_key", WS_API_KEY);
  url.searchParams.set("format", "json");
  url.searchParams.set("currency", currency);
  if (lwin) url.searchParams.set("lwin", lwin);
  if (q) url.searchParams.set("keyword", q);
  if (vintage) url.searchParams.set("vintage", vintage);

  const r = await fetch(url, { signal: AbortSignal.timeout(15000) });
  if (!r.ok) throw new Error("ws http " + r.status);
  const j = await r.json();

  // --- ADJUST these paths to the real response shape -----------------------
  const priceInfo = j?.["wine-prices"]?.[0] ?? j?.prices ?? j ?? {};
  const rawOffers = priceInfo?.offers ?? j?.offers ?? [];
  const offers = (Array.isArray(rawOffers) ? rawOffers : []).map((o) => ({
    merchant: o.name ?? o.merchant ?? o.seller ?? "Merchant",
    price: num(o.price ?? o.price_inc_tax ?? o.amount),
    currency: o.currency ?? currency,
    url: o.url ?? o.link ?? null,
    address: o.address ?? ([o.city, o.region, o.country].filter(Boolean).join(", ") || null),
    latitude: num(o.latitude ?? o.lat),
    longitude: num(o.longitude ?? o.lng ?? o.lon),
    inStock: o.in_stock ?? o.available ?? true,
  }));
  const prices = offers.map((o) => o.price).filter((n) => typeof n === "number");
  const out = contract({
    average: num(priceInfo.average ?? priceInfo.average_price) ?? (prices.length ? avg(prices) : null),
    min: num(priceInfo.min ?? priceInfo.min_price) ?? (prices.length ? Math.min(...prices) : null),
    max: num(priceInfo.max ?? priceInfo.max_price) ?? (prices.length ? Math.max(...prices) : null),
    currency,
    score: num(priceInfo.score ?? j?.score ?? j?.wine_score),
    image: priceInfo.image ?? j?.image ?? j?.image_url ?? null,
    offers,
    source: "wine-searcher",
  });
  // Set DEBUG_UPSTREAM=1 to see the raw provider JSON alongside the mapped
  // result, so you can correct the field paths above for your API's response.
  if (process.env.DEBUG_UPSTREAM === "1") out._raw = j;
  return out;
}

// ---- Apify adapter (mrbridge~vivino-wine-data-scraper, pay-per-result) ------
// Field names verified against live runs (2026-09-16). The actor searches
// Vivino by wine name and returns a row per candidate match, carrying that
// vintage's community rating and one retail price. It runs on Apify's free
// plan without residential proxies — the previous Wine-Searcher actor needed
// them and refused every lookup without them. The token goes in a header.
//
// Trade-off: Vivino gives a single price and at most one merchant link per
// wine, not a list of offers, so "Where to buy" is thin online. Nearby stores
// come from MapKit on the phone and are unaffected.
const APIFY_MARKET = {
  USD: "US", GBP: "GB", CAD: "CA", AUD: "AU", NZD: "NZ", EUR: "FR", CHF: "CH", SEK: "SE",
};

async function lookupApify({ q, lwin, vintage, currency }) {
  if (!APIFY_TOKEN) throw new Error("apify not configured");
  // The actor searches by name and has no LWIN input; the app always sends a
  // name next to the code, so a code-only lookup means something upstream broke.
  if (!q) throw new Error("apify needs a wine name");

  const wanted = /^\d{4}$/.test(vintage) ? Number(vintage) : null;
  const market = APIFY_MARKET[currency] ?? "US";

  // Vivino's own name for a wine is often not what's on the label — Veuve
  // Clicquot "Yellow Label" is listed as "Brut (Carte Jaune)" — and a query the
  // actor can't match returns nothing at all. Sending a producer-only variant
  // (the first two words) in the same run rescues those misses for the price of
  // one extra result, and the ranking below still prefers the full-name hits.
  const full = wanted ? `${q} ${wanted}` : q;
  const words = q.split(/\s+/).filter(Boolean);
  const wines = words.length > 2 ? [full, words.slice(0, 2).join(" ")] : [full];
  const input = {
    wines,
    searchMode: "auto",
    matchingMode: "advanced",
    includeTasteProfile: false,
    includeReviews: false,
    countryCode: market,
    shipTo: market,
    currencyCode: currency,
  };

  const r = await fetch(`https://api.apify.com/v2/acts/${APIFY_ACTOR}/run-sync-get-dataset-items`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${APIFY_TOKEN}` },
    body: JSON.stringify(input),
    signal: AbortSignal.timeout(120000),
  });
  if (!r.ok) throw new Error("apify http " + r.status);
  const items = await r.json();

  // Per-750 mL comparisons: 700 mL, 750 mL and 1 L scale to a standard bottle;
  // half bottles, magnums and other formats don't scale linearly, so their
  // prices are dropped rather than extrapolated. No size stated = a bottle.
  const priceOf = (it) => {
    const p = num(it.price);
    if (p === null) return null;
    const ml = num(it.bottle_volume_ml) ?? 750;
    if (![700, 750, 1000].some((v) => Math.abs(ml - v) < 5)) return null;
    return { amount: p, ml, currency: it.currency || currency };
  };

  // A search that finds nothing still emits one placeholder row named
  // "Not found" with every field null — drop those so they can't be ranked.
  const found = (Array.isArray(items) ? items : [])
    .filter((it) => it && it.vivino_url && !/^not found$/i.test(String(it.name ?? "")));

  // One search can return several candidates — "Opus One" also matches that
  // winery's "Overture". matchScore is the actor's own name-similarity rank;
  // the requested vintage outranks it, and a usable bottle size breaks ties.
  // A non-vintage request should land on a non-vintage bottle, and among
  // equally good names the one the most people have rated is the one on the
  // shelf (the producer-only variant returns the winery's whole range at rank 1).
  const ranked = found
    .map((it) => ({
      it,
      rank: (num(it.matchScore) ?? 0)
        + (wanted !== null && num(it.vintage) === wanted ? 10 : 0)
        + (wanted === null && it.vintage === null ? 2 : 0)
        + (priceOf(it) ? 1 : 0),
      ratings: num(it.ratings_count) ?? 0,
    }))
    .sort((a, b) => b.rank - a.rank || b.ratings - a.ratings);
  const best = ranked[0]?.it;
  if (!best) return contract({ currency, source: "vivino" });

  const priced = priceOf(best);
  const price = priced
    ? money(priced.amount * (750 / priced.ml) * await fxRate(priced.currency, currency))
    : null;

  // The app shows scores on the 100-point scale; Vivino rates out of 5. Prefer
  // this vintage's rating, fall back to the wine's across vintages, and ignore
  // a rating backed by only a handful of reviews.
  const vintageStars = (num(best.ratings_count) ?? 0) >= 3 ? num(best.average_rating) : null;
  const wineStars = (num(best.wine_ratings_count) ?? 0) >= 3 ? num(best.wine_average_rating) : null;
  const stars = vintageStars ?? wineStars;

  // Vivino links at most one merchant, and only when it quoted a price.
  const offers = price !== null && best.merchant_url ? [{
    merchant: merchantName(best.merchant_url),
    price,
    currency,
    url: best.merchant_url,
    address: null,
    latitude: null,
    longitude: null,
    inStock: true,
  }] : [];

  const out = contract({
    average: price,
    // A single quote is not a range, so min/max stay empty rather than
    // repeating the average back as if it were a spread.
    min: null,
    max: null,
    currency,
    score: stars === null ? null : Math.round(stars * 20),
    image: best.image_url ?? best.label_image_url ?? null,
    offers,
    source: "vivino",
  });
  if (process.env.DEBUG_UPSTREAM === "1") out._raw = best;
  return out;
}

// ---- Currency conversion (ECB reference rates via frankfurter.app, no key) ----
const fxCache = new Map(); // "EUR>USD" -> { rate, at }
async function fxRate(from, to) {
  if (!from || !to || from === to) return 1;
  const key = `${from}>${to}`;
  const hit = fxCache.get(key);
  if (hit && Date.now() - hit.at < 12 * 3600 * 1000) return hit.rate;
  try {
    const r = await fetch(`https://api.frankfurter.app/latest?from=${encodeURIComponent(from)}&to=${encodeURIComponent(to)}`,
      { signal: AbortSignal.timeout(10000) });
    if (!r.ok) throw new Error("fx http " + r.status);
    const rate = (await r.json())?.rates?.[to];
    if (typeof rate !== "number") throw new Error("fx rate missing for " + to);
    fxCache.set(key, { rate, at: Date.now() });
    return rate;
  } catch (err) {
    if (hit) return hit.rate; // a stale rate beats no price
    throw err;
  }
}

// ---- helpers ----------------------------------------------------------------
function num(v) {
  if (v === null || v === undefined || v === "") return null;
  const n = typeof v === "number" ? v : parseFloat(String(v).replace(/[^0-9.]/g, ""));
  return Number.isFinite(n) ? n : null;
}
function money(n) { return Math.round(n * 100) / 100; }
function merchantName(url) {
  try { return new URL(url).hostname.replace(/^www\./, ""); } catch { return "Merchant"; }
}
function avg(arr) { return Math.round((arr.reduce((a, b) => a + b, 0) / arr.length) * 100) / 100; }

app.listen(Number(PORT), HOST, () => {
  console.log(`cellar-proxy listening on http://${HOST}:${PORT} (provider=${PROVIDER})`);
});
