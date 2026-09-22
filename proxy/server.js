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
import { readFileSync, writeFileSync, renameSync, statSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";

const {
  PORT = "8787",
  HOST = "127.0.0.1",
  PROVIDER = "mock",                 // mock | winesearcher | apify
  PROXY_TOKEN = "",                  // if set, the app must send it as a Bearer token
  WS_API_URL = "",                   // Wine-Searcher API base (from their docs)
  WS_API_KEY = "",                   // Wine-Searcher API key (secret)
  APIFY_TOKEN = "",                  // Apify token (secret)
  APIFY_ACTOR = "mrbridge~vivino-wine-data-scraper",
  APIFY_WS_ACTOR = "mrbridge~wine-searcher-scraper-from-list", // "" disables the critic-score half
  WS_GRACE_SECONDS = "6",            // how long a lookup waits for the critic score
  WS_TIMEOUT_SECONDS = "110",        // how long that half runs before giving up
  CACHE_TTL_SECONDS = "604800",      // 7 days — matches the app's per-wine TTL
  CACHE_FILE = "./cache.json",       // survives restarts; "" keeps the cache in memory only
  RATE_LIMIT_PER_MIN = "60",
  DEVICES_FILE = "./devices.json",   // per-install roster + usage counters
  DEVICE_DAILY_LIMIT = "100",        // billable lookups per device per day (0 = unlimited)
  DEVICE_MONTHLY_LIMIT = "300",      // ...and per calendar month (0 = unlimited)
  GLOBAL_MONTHLY_LIMIT = "1500",     // billable lookups across ALL devices per month (0 = unlimited)
  MAX_DEVICES = "10",                // how many installs may self-enrol
  ALLOW_UNKNOWN_DEVICES = "1",       // 0 = only ids already in the file may look up
  REQUIRE_DEVICE = "0",              // 1 = reject requests with no device header
  OWNER_DEVICE = "",                 // this id is enrolled unlimited on startup
  ADMIN_TOKEN = "",                  // bearer token for GET /admin/devices
} = process.env;

const CACHE_TTL_MS = Number(CACHE_TTL_SECONDS) * 1000;
const WS_GRACE_MS = Number(WS_GRACE_SECONDS) * 1000;
const WS_TIMEOUT_MS = Number(WS_TIMEOUT_SECONDS) * 1000;
const RATE_LIMIT = Number(RATE_LIMIT_PER_MIN);
const DEVICE_CAP = Number(MAX_DEVICES);

// Limits start from the environment and can then be changed from the owner's
// phone (Settings → Monthly cap), which persists them in DEVICES_FILE. A stored
// value wins so a restart keeps what was set; delete the "limits" block in that
// file to fall back to the environment.
const limits = {
  daily: Number(DEVICE_DAILY_LIMIT),
  monthly: Number(DEVICE_MONTHLY_LIMIT),
  globalMonthly: Number(GLOBAL_MONTHLY_LIMIT),
};
/// Billable lookups across every device this calendar month — the ceiling that
/// bounds the bill when the proxy runs open, since a fresh device id would
/// otherwise start a fresh allowance.
let globalUsage = { month: "", count: 0 };

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

// ---- Response cache, persisted so a restart doesn't re-scrape everything ----
// A cold lookup costs ~30 s and a few tenths of a cent, so losing the cache to a
// container restart is worth avoiding. Writes are debounced and atomic (temp
// file + rename), and a cache that can't be read or written is never fatal —
// the proxy just runs from memory.
const cache = new Map(); // key -> { at, body }
function cacheGet(key) {
  const rec = cache.get(key);
  if (rec && Date.now() - rec.at < CACHE_TTL_MS) return rec.body;
  if (rec) {
    cache.delete(key);
    saveCacheSoon();
  }
  return null;
}
function cacheSet(key, body) {
  cache.set(key, { at: Date.now(), body });
  saveCacheSoon();
}

function loadCache() {
  if (!CACHE_FILE) return;
  try {
    const stored = JSON.parse(readFileSync(CACHE_FILE, "utf8"));
    let expired = 0;
    for (const [key, rec] of Object.entries(stored)) {
      if (rec && typeof rec.at === "number" && Date.now() - rec.at < CACHE_TTL_MS) cache.set(key, rec);
      else expired += 1;
    }
    console.log(`cache: loaded ${cache.size} entries (${expired} expired)`);
  } catch (err) {
    if (err?.code !== "ENOENT") console.error("cache load failed:", err?.message || "error");
  }
}

let saveTimer = null;
function saveCacheNow() {
  if (!CACHE_FILE) return;
  saveTimer = null;
  try {
    const tmp = `${CACHE_FILE}.tmp`;
    writeFileSync(tmp, JSON.stringify(Object.fromEntries(cache)));
    renameSync(tmp, CACHE_FILE);   // atomic: a crash mid-write can't truncate the cache
  } catch (err) {
    console.error("cache save failed:", err?.message || "error");
  }
}
/// Coalesce the writes from a burst of lookups into one.
function saveCacheSoon() {
  if (!CACHE_FILE || saveTimer) return;
  saveTimer = setTimeout(saveCacheNow, 2000);
  saveTimer.unref?.();           // never hold the process open just to save
}

for (const signal of ["SIGTERM", "SIGINT"]) {
  process.on(signal, () => {
    saveCacheNow();              // a restart keeps whatever the last lookups found
    saveDevicesNow();
    process.exit(0);
  });
}

// ---- Per-device enrolment and quotas ---------------------------------------
// Every install sends `X-Cellar-Device: Ryc#j0` — a short id generated once and
// kept in its Keychain. Two reasons it exists: you can see which friend is
// spending your provider credits, and you can cap or cut off one of them without
// rotating the token everyone shares.
//
// Only a lookup that actually reaches the provider counts against a quota — a
// cache hit costs nothing, so it is never charged to anyone. The file is re-read
// whenever it changes on disk, so raising a cap or revoking a device takes effect
// without a restart; the server owns the counters, you own the limits.
const devices = new Map(); // id -> { name, dailyLimit, monthlyLimit, revoked, day, dayCount, … }
let devicesMtime = 0;

const dayKey = (d = new Date()) => d.toISOString().slice(0, 10);   // 2026-09-22
const monthKey = (d = new Date()) => d.toISOString().slice(0, 7);  // 2026-09

/// Ids are opaque to us; just keep them short, printable, and log-safe.
function validDeviceId(id) {
  return typeof id === "string" && /^[A-Za-z0-9#_-]{4,32}$/.test(id);
}

function blankDevice(extra = {}) {
  return {
    name: "",
    dailyLimit: null,          // null = fall back to DEVICE_DAILY_LIMIT
    monthlyLimit: null,
    revoked: false,
    firstSeen: new Date().toISOString(),
    lastSeen: null,
    day: dayKey(), dayCount: 0,
    month: monthKey(), monthCount: 0,
    total: 0,
    ...extra,
  };
}

function loadDevices() {
  if (!DEVICES_FILE) return;
  try {
    const stat = statSync(DEVICES_FILE);
    if (stat.mtimeMs === devicesMtime) return;      // unchanged since we last read/wrote
    devicesMtime = stat.mtimeMs;
    const stored = JSON.parse(readFileSync(DEVICES_FILE, "utf8"));
    for (const key of ["daily", "monthly", "globalMonthly"]) {
      const v = stored?.limits?.[key];
      if (Number.isFinite(v) && v >= 0) limits[key] = Number(v);
    }
    if (stored?.global && typeof stored.global.month === "string") {
      // Keep whichever count is higher: ours may have advanced since the write.
      if (stored.global.month === globalUsage.month) {
        globalUsage.count = Math.max(globalUsage.count, Number(stored.global.count) || 0);
      } else if (!globalUsage.month) {
        globalUsage = { month: stored.global.month, count: Number(stored.global.count) || 0 };
      }
    }
    for (const [id, rec] of Object.entries(stored?.devices || {})) {
      if (!validDeviceId(id) || !rec) continue;
      const live = devices.get(id);
      // You own the limits (edit them in the file); the server owns the counters,
      // so an edit made while it is running can't roll usage back to zero.
      devices.set(id, {
        ...blankDevice(),
        ...rec,
        ...(live ? { day: live.day, dayCount: live.dayCount, month: live.month,
                     monthCount: live.monthCount, total: live.total,
                     lastSeen: live.lastSeen, firstSeen: live.firstSeen } : {}),
      });
    }
    console.log(`devices: ${devices.size} enrolled`);
  } catch (err) {
    if (err?.code !== "ENOENT") console.error("devices load failed:", err?.message || "error");
  }
}

let devicesTimer = null;
function saveDevicesNow() {
  if (!DEVICES_FILE) return;
  devicesTimer = null;
  try {
    const tmp = `${DEVICES_FILE}.tmp`;
    writeFileSync(tmp, JSON.stringify({
      limits: { ...limits },
      global: globalSnapshot(),
      devices: Object.fromEntries(devices),
    }, null, 2));
    renameSync(tmp, DEVICES_FILE);
    devicesMtime = statSync(DEVICES_FILE).mtimeMs;  // our own write isn't an outside edit
  } catch (err) {
    console.error("devices save failed:", err?.message || "error");
  }
}
function saveDevicesSoon() {
  if (!DEVICES_FILE || devicesTimer) return;
  devicesTimer = setTimeout(saveDevicesNow, 2000);
  devicesTimer.unref?.();
}

/// Roll the day/month counters over when the clock passes midnight / month end.
function rollCounters(rec) {
  const today = dayKey(), month = monthKey();
  if (rec.day !== today) { rec.day = today; rec.dayCount = 0; }
  if (rec.month !== month) { rec.month = month; rec.monthCount = 0; }
}

const effectiveLimit = (own, fallback) => (own === null || own === undefined ? fallback : Number(own));

/// This month's total, rolled over at the month boundary.
function globalSnapshot() {
  const month = monthKey();
  if (globalUsage.month !== month) globalUsage = { month, count: 0 };
  return { month: globalUsage.month, count: globalUsage.count, limit: limits.globalMonthly };
}

/// May this device make a lookup that could cost money? Enrols a new one the
/// first time it appears, up to MAX_DEVICES.
function deviceCheck(id) {
  loadDevices();
  if (!id) {
    return REQUIRE_DEVICE === "1"
      ? { ok: false, status: 400, error: "device_required" }
      : { ok: true, rec: null };
  }
  if (!validDeviceId(id)) return { ok: false, status: 400, error: "bad_device_id" };

  let rec = devices.get(id);
  if (!rec) {
    if (ALLOW_UNKNOWN_DEVICES !== "1") return { ok: false, status: 403, error: "device_not_enrolled" };
    if (DEVICE_CAP > 0 && devices.size >= DEVICE_CAP) {
      return { ok: false, status: 403, error: "device_limit_reached" };
    }
    rec = blankDevice();
    devices.set(id, rec);
    console.log(`devices: enrolled ${id} (${devices.size}/${DEVICE_CAP || "∞"})`);
    saveDevicesSoon();
  }
  if (rec.revoked) return { ok: false, status: 403, error: "device_revoked" };
  return { ok: true, rec };
}

/// Checked only once a lookup is about to reach the provider, so a cache hit is
/// free and a friend is never charged for a wine someone else already priced.
function quotaCheck(rec) {
  // The ceiling on everyone together comes first: it is what bounds the bill when
  // the proxy runs without a token and anyone can enrol.
  const total = globalSnapshot();
  if (total.limit > 0 && total.count >= total.limit) {
    return { ok: false, status: 429, error: "service_limit_reached", limit: total.limit };
  }
  if (!rec) return { ok: true };
  rollCounters(rec);
  const daily = effectiveLimit(rec.dailyLimit, limits.daily);
  const monthly = effectiveLimit(rec.monthlyLimit, limits.monthly);
  if (daily > 0 && rec.dayCount >= daily) {
    return { ok: false, status: 429, error: "daily_limit_reached", limit: daily };
  }
  if (monthly > 0 && rec.monthCount >= monthly) {
    return { ok: false, status: 429, error: "monthly_limit_reached", limit: monthly };
  }
  return { ok: true };
}

/// Called only when a lookup actually reaches the provider — i.e. costs money.
function noteBillable(rec) {
  const total = globalSnapshot();          // rolls the month over if needed
  globalUsage.count = total.count + 1;
  if (!rec) { saveDevicesSoon(); return; }
  rollCounters(rec);
  rec.dayCount += 1;
  rec.monthCount += 1;
  rec.total += 1;
  rec.lastSeen = new Date().toISOString();
  saveDevicesSoon();
}

loadDevices();
if (OWNER_DEVICE && validDeviceId(OWNER_DEVICE) && !devices.get(OWNER_DEVICE)) {
  devices.set(OWNER_DEVICE, blankDevice({ name: "owner", dailyLimit: 0, monthlyLimit: 0 }));
  saveDevicesSoon();
}

// ---- Public pages -----------------------------------------------------------
// The App Store listing needs a support URL and a privacy URL that stay up. They
// are plain static HTML served from here so there is one host to keep alive, not
// two. No cache headers beyond a short one: a privacy policy that can't be
// corrected quickly is worse than one fetched twice.
const PUBLIC_DIR = join(dirname(fileURLToPath(import.meta.url)), "public");
for (const [routes, file] of [[["/support", "/support.html"], "support.html"],
                              [["/privacy", "/privacy.html", "/privacy-policy"], "privacy.html"]]) {
  app.get(routes, (_req, res) => {
    res.set("Cache-Control", "public, max-age=300");
    res.sendFile(join(PUBLIC_DIR, file), (err) => {
      if (err) res.status(500).type("text/plain").send("page unavailable");
    });
  });
}

app.get("/health", (_req, res) => res.json({ ok: true, provider: PROVIDER }));

/// The owner's phone (Settings → Monthly cap) and your terminal both authenticate
/// with ADMIN_TOKEN. Unset = the admin endpoints don't exist at all.
function adminOK(req) {
  if (!ADMIN_TOKEN) return false;
  const m = /^Bearer\s+(.+)$/.exec(req.headers.authorization || "");
  const given = Buffer.from(m?.[1] || "");
  const want = Buffer.from(ADMIN_TOKEN);
  return given.length === want.length && timingSafeEqual(given, want);
}

/// Read the caps in force, and this month's total. The app shows these before
/// changing anything, so the owner is never editing blind.
app.get("/admin/limits", (req, res) => {
  if (!ADMIN_TOKEN) return res.status(404).json({ error: "not_found" });
  if (!adminOK(req)) return res.status(401).json({ error: "unauthorized" });
  loadDevices();
  res.json({ limits: { ...limits }, global: globalSnapshot(), devices: devices.size });
});

/// Change them from the owner's phone: 10 while the app is in review, 100 after.
/// Values are clamped to something sane and persisted, so a restart keeps them.
app.patch("/admin/limits", express.json({ limit: "4kb" }), (req, res) => {
  if (!ADMIN_TOKEN) return res.status(404).json({ error: "not_found" });
  if (!adminOK(req)) return res.status(401).json({ error: "unauthorized" });
  loadDevices();
  const MAX = 100000;
  for (const [field, key] of [["monthlyLimit", "monthly"], ["dailyLimit", "daily"],
                              ["globalMonthlyLimit", "globalMonthly"]]) {
    const v = req.body?.[field];
    if (v === undefined || v === null) continue;
    const n = Number(v);
    if (!Number.isFinite(n) || n < 0 || n > MAX) {
      return res.status(400).json({ error: "bad_limit", field });
    }
    limits[key] = Math.floor(n);
  }
  saveDevicesNow();
  console.log(`limits: device ${limits.monthly}/month, ${limits.daily}/day, service ${limits.globalMonthly}/month`);
  res.json({ limits: { ...limits }, global: globalSnapshot() });
});

// Who is using your provider credits, and how much.
app.get("/admin/devices", (req, res) => {
  if (!ADMIN_TOKEN) return res.status(404).json({ error: "not_found" });
  if (!adminOK(req)) return res.status(401).json({ error: "unauthorized" });
  loadDevices();
  const rows = [...devices.entries()].map(([id, rec]) => {
    rollCounters(rec);
    return {
      id, name: rec.name, revoked: rec.revoked,
      today: rec.dayCount, dailyLimit: effectiveLimit(rec.dailyLimit, limits.daily),
      thisMonth: rec.monthCount, monthlyLimit: effectiveLimit(rec.monthlyLimit, limits.monthly),
      total: rec.total, firstSeen: rec.firstSeen, lastSeen: rec.lastSeen,
    };
  });
  res.json({ devices: rows, limits: { ...limits }, global: globalSnapshot(),
             cacheEntries: cache.size });
});

app.get("/valuation", async (req, res) => {
  const ip = req.ip || req.socket.remoteAddress || "unknown";
  if (rateLimited(ip)) return res.status(429).json({ error: "rate_limited" });
  if (!tokenOK(req.headers.authorization)) return res.status(401).json({ error: "unauthorized" });

  const access = deviceCheck(String(req.headers["x-cellar-device"] || "").trim());
  if (!access.ok) return res.status(access.status).json({ error: access.error });

  const lwin = String(req.query.lwin || "").trim();
  const q = String(req.query.q || "").trim();
  const vintage = String(req.query.vintage || "").trim();
  const currency = String(req.query.currency || "USD").trim().toUpperCase();
  if (!lwin && !q) return res.status(400).json({ error: "missing_query" });

  const cacheKey = JSON.stringify({ lwin, q, vintage, currency, PROVIDER });
  const cached = cacheGet(cacheKey);
  // Entries cached before images were dropped still carry one, and a cached body
  // is returned verbatim — so strip it here as well as at the point of building.
  if (cached) return res.json({ ...cached, image: null });   // free: nobody's quota is touched

  const quota = quotaCheck(access.rec);
  if (!quota.ok) return res.status(quota.status).json({ error: quota.error, limit: quota.limit });

  try {
    noteBillable(access.rec);                // this one is going to the provider
    const body = await lookup({ lwin, q, vintage, currency },
                              (late) => cacheSet(cacheKey, late));
    cacheSet(cacheKey, body);
    res.json(body);
  } catch (err) {
    // Never leak the provider key or full upstream URL in errors/logs.
    console.error("lookup failed:", err?.message || "error");
    res.status(502).json({ error: "provider_error" });
  }
});

// ---- Provider dispatch ------------------------------------------------------
async function lookup(params, onLate = () => {}) {
  switch (PROVIDER) {
    case "winesearcher": return await lookupWineSearcher(params);
    case "apify":        return await lookupApify(params, onLate);
    default:             return lookupMock(params);
  }
}

// The app's contract. Every adapter returns this shape.
function contract({ average = null, min = null, max = null, currency = "USD", score = null, image = null, offers = [], source = null }) {
  // `image` is accepted from the adapters and then dropped on purpose: a label
  // photograph belongs to whoever took it, and the app no longer displays one it
  // didn't take. Nulled here so no provider path can leak a URL to any client,
  // including builds older than this change.
  void image;
  return { average, min, max, currency, score, image: null, offers, source };
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

// ---- Apify adapters ---------------------------------------------------------
// Two actors from the same publisher, run in parallel and merged, because they
// know different things (field names verified against live runs, 2026-09-16):
//
//   • mrbridge~vivino-wine-data-scraper — a retail price, the community rating
//     and a label image. ~20 s.
//   • mrbridge~wine-searcher-scraper-from-list — the aggregated CRITIC score and
//     the cheapest price on the market, already converted to the currency asked
//     for. It takes ~80 s against Vivino's ~20 s, so it gets its own deadline
//     (inside the app's request timeout) and is dropped if it's late rather than
//     holding up a price the other half already has.
//
// Neither needs Apify residential proxies, so both run on the free plan. (The
// older abotapi~wine-searcher-scraper did, and failed every lookup without it.)
const APIFY_MARKET = {
  USD: "US", GBP: "GB", CAD: "CA", AUD: "AU", NZD: "NZ", EUR: "FR", CHF: "CH", SEK: "SE",
};

async function apifyRun(actor, input, timeoutMs) {
  const r = await fetch(`https://api.apify.com/v2/acts/${actor}/run-sync-get-dataset-items`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${APIFY_TOKEN}` },
    body: JSON.stringify(input),
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!r.ok) throw new Error("apify http " + r.status);
  const items = await r.json();
  return Array.isArray(items) ? items : [];
}

async function lookupApify({ q, lwin, vintage, currency }, onLate = () => {}) {
  if (!APIFY_TOKEN) throw new Error("apify not configured");
  // Both actors search by name and neither takes an LWIN code; the app always
  // sends a name next to the code, so a code-only lookup means something broke.
  if (!q) throw new Error("apify needs a wine name");

  // One slow provider must not sink the lookup: whatever answers is used.
  const settle = (label) => (err) => {
    console.error(`${label} lookup failed:`, err?.message || "error");
    return null;
  };
  const vivinoPromise = lookupVivinoActor({ q, vintage, currency }).catch(settle("vivino"));
  const wsPromise = APIFY_WS_ACTOR
    ? lookupWineSearcherActor({ q, vintage, currency }).catch(settle("wine-searcher"))
    : Promise.resolve(null);

  const vivino = await vivinoPromise;
  // Wine-Searcher takes ~80 s against Vivino's ~20 s. Waiting for it would make
  // every cold lookup as slow as the slowest half, so once there's something to
  // show it gets only a short grace period (it's often already warm). If it's
  // late we answer now and fold its critic score into the cache when it lands,
  // so the next request — or the app's next refresh — has it without waiting.
  // With nothing else to show, there's nothing to gain by answering early.
  const grace = vivino ? WS_GRACE_MS : WS_TIMEOUT_MS;
  const late = Symbol("late");
  let ws = await Promise.race([wsPromise, sleep(grace).then(() => late)]);
  if (ws === late) {
    ws = null;
    wsPromise.then((result) => { if (result) onLate(mergeApify({ vivino, ws: result, currency })); })
      .catch(() => {});
  }

  const out = mergeApify({ vivino, ws, currency });
  if (!vivino && !ws) throw new Error("no provider answered");
  if (process.env.DEBUG_UPSTREAM === "1") out._raw = { vivino: vivino?._raw, ws: ws?._raw };
  return out;
}

// Vivino's price is a typical retail asking price, so it's the better estimate
// of what a bottle is worth; Wine-Searcher's is the cheapest listing on the
// market, which is the floor. Its score is a real critic aggregate and beats a
// community star average whenever it's there.
function mergeApify({ vivino, ws, currency }) {
  return contract({
    average: vivino?.average ?? ws?.average ?? null,
    min: ws?.min ?? null,
    max: null,
    currency,
    score: ws?.score ?? vivino?.score ?? null,
    image: vivino?.image ?? ws?.image ?? null,
    offers: [...(ws?.offers ?? []), ...(vivino?.offers ?? [])],
    source: [ws && "wine-searcher", vivino && "vivino"].filter(Boolean).join(" + ") || null,
  });
}

// ---- Vivino: price, community rating, label image ---------------------------
async function lookupVivinoActor({ q, vintage, currency }) {
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

  const items = await apifyRun(APIFY_ACTOR, {
    wines,
    searchMode: "auto",
    matchingMode: "advanced",
    includeTasteProfile: false,
    includeReviews: false,
    countryCode: market,
    shipTo: market,
    currencyCode: currency,
  }, 120000);

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
  const found = items.filter((it) => it && it.vivino_url && !/^not found$/i.test(String(it.name ?? "")));

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
  if (!best) return null;

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

  return {
    average: price,
    score: stars === null ? null : Math.round(stars * 20),
    image: best.image_url ?? best.label_image_url ?? null,
    offers,
    _raw: best,
  };
}

// ---- Wine-Searcher: critic score and the cheapest listing -------------------
async function lookupWineSearcherActor({ q, vintage, currency }) {
  const wanted = /^\d{4}$/.test(vintage) ? Number(vintage) : null;
  const items = await apifyRun(APIFY_WS_ACTOR, {
    inputType: "wineNames",
    wineNames: [wanted ? `${q} ${wanted}` : q],
    targetCurrency: currency,
  }, WS_TIMEOUT_MS);
  const f = items[0];
  if (!f || (f.status && f.status !== "ok")) return null;

  // cheapestPriceConverted is per bottle in targetCurrency (a case listing is
  // already quoted per bottle); fall back to the raw amount and convert it.
  let cheapest = num(f.cheapestPriceConverted);
  const target = f.targetCurrency || currency;
  if (cheapest !== null && target !== currency) cheapest = money(cheapest * await fxRate(target, currency));
  if (cheapest === null) {
    const raw = num(f.cheapestPriceAmount);
    if (raw !== null) cheapest = money(raw * await fxRate(f.cheapestPriceCurrency || currency, currency));
  }

  const offers = cheapest !== null && f.cheapestPriceMerchant ? [{
    merchant: f.cheapestPriceMerchant,
    price: cheapest,
    currency,
    url: f.wineSearcherUrl ?? null,
    address: null,
    latitude: null,
    longitude: null,
    inStock: true,
  }] : [];

  return {
    average: cheapest,
    min: cheapest,
    score: num(f.score),          // already a 100-point critic aggregate
    image: f.labelImageUrl ?? null,
    offers,
    _raw: f,
  };
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
function sleep(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }
function merchantName(url) {
  try { return new URL(url).hostname.replace(/^www\./, ""); } catch { return "Merchant"; }
}
function avg(arr) { return Math.round((arr.reduce((a, b) => a + b, 0) / arr.length) * 100) / 100; }

loadCache();
app.listen(Number(PORT), HOST, () => {
  console.log(`cellar-proxy listening on http://${HOST}:${PORT} (provider=${PROVIDER})`);
});
