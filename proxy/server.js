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
  APIFY_ACTOR = "abotapi~wine-searcher-scraper",
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
function contract({ average = null, min = null, max = null, currency = "USD", score = null, image = null, offers = [] }) {
  return { average, min, max, currency, score, image, offers };
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
  return contract({ average: avg, min, max, currency, score, image, offers });
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
  });
  // Set DEBUG_UPSTREAM=1 to see the raw provider JSON alongside the mapped
  // result, so you can correct the field paths above for your API's response.
  if (process.env.DEBUG_UPSTREAM === "1") out._raw = j;
  return out;
}

// ---- Apify adapter (abotapi~wine-searcher-scraper, pay-per-result) ----------
// Input/output field names follow the actor's published input schema and
// example output. The actor needs Apify residential proxies (a paid Apify plan);
// the proxy country sets the price currency. The token goes in a header, never
// the URL.
const APIFY_COUNTRY = { USD: "US", GBP: "GB", EUR: "FR", CAD: "CA", AUD: "AU" };

async function lookupApify({ q, lwin, vintage, currency }) {
  if (!APIFY_TOKEN) throw new Error("apify not configured");
  const input = {
    fetchOffers: true,
    maxItems: 1,
    proxy: {
      useApifyProxy: true,
      apifyProxyGroups: ["RESIDENTIAL"],
      apifyProxyCountry: APIFY_COUNTRY[currency] ?? "US",
    },
  };
  // Prefer the name: the app's bundled LWIN sample codes are illustrative.
  if (q) {
    input.inputType = "wineNames";
    input.wineNames = [[q, vintage].filter(Boolean).join(" ")];
  } else {
    input.inputType = "lwins";
    input.lwins = [lwin];
  }

  const r = await fetch(`https://api.apify.com/v2/acts/${APIFY_ACTOR}/run-sync-get-dataset-items`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${APIFY_TOKEN}` },
    body: JSON.stringify(input),
    signal: AbortSignal.timeout(120000),
  });
  if (!r.ok) throw new Error("apify http " + r.status);
  const items = await r.json();
  const first = Array.isArray(items) ? items[0] ?? {} : {};
  const priceCurrency = first.avgPriceCurrency ?? first.cheapestPriceCurrency ?? currency;

  // Keep 750 mL listings only (cases are divided down to a per-bottle price),
  // so offers compare with the app's per-750 mL valuation.
  const offers = (Array.isArray(first.offers) ? first.offers : [])
    .filter((o) => !o.unitDescription || /750\s*ml/i.test(o.unitDescription))
    .map((o) => {
      const perUnit = num(o.price);
      const bottles = Number(o.bottlesPerUnit) > 1 ? Number(o.bottlesPerUnit) : 1;
      return {
        merchant: o.merchant ?? "Merchant",
        price: perUnit === null ? null : Math.round((perUnit / bottles) * 100) / 100,
        currency: o.priceCurrency ?? priceCurrency,
        url: o.merchantUrl ?? first.wineSearcherUrl ?? null,
        address: null,
        latitude: null,
        longitude: null,
        inStock: o.availability ? /instock/i.test(o.availability) : true,
      };
    });
  const prices = offers.map((o) => o.price).filter((n) => typeof n === "number");

  // The app shows scores on the 100-point scale.
  let score = num(first.score);
  const best = num(first.scoreBestRating);
  if (score !== null && best && best !== 100) score = Math.round((score / best) * 100);

  const out = contract({
    average: num(first.avgPrice) ?? num(first.medianPriceAmount) ?? (prices.length ? avg(prices) : null),
    min: num(first.cheapestPriceAmount) ?? (prices.length ? Math.min(...prices) : null),
    max: num(first.highestPriceAmount) ?? (prices.length ? Math.max(...prices) : null),
    currency: priceCurrency,
    score,
    image: first.labelImageUrl ?? null,
    offers,
  });
  if (process.env.DEBUG_UPSTREAM === "1") out._raw = first;
  return out;
}

// ---- helpers ----------------------------------------------------------------
function num(v) {
  if (v === null || v === undefined || v === "") return null;
  const n = typeof v === "number" ? v : parseFloat(String(v).replace(/[^0-9.]/g, ""));
  return Number.isFinite(n) ? n : null;
}
function avg(arr) { return Math.round((arr.reduce((a, b) => a + b, 0) / arr.length) * 100) / 100; }

app.listen(Number(PORT), HOST, () => {
  console.log(`cellar-proxy listening on http://${HOST}:${PORT} (provider=${PROVIDER})`);
});
