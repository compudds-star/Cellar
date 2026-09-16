# Cellar pricing proxy

A ~200-line Node service that sits between the Cellar app and a wine-pricing
provider. It:

- serves `GET /valuation` in the **exact JSON contract** the app expects;
- holds the **provider API key server-side** (never in the app);
- authenticates the app with a **separate bearer token** you can rotate;
- **caches 7 days per wine** and **rate-limits per IP** to keep provider cost near zero;
- adapts **Wine-Searcher**, **Apify**, or a built-in **mock** (default).

## Run locally (mock, no keys)

```bash
cd proxy
npm install
PROVIDER=mock PORT=8787 npm start
curl "http://127.0.0.1:8787/valuation?q=Opus%20One&vintage=2018"
```

You'll get back the contract JSON. Point the app's Settings → endpoint at
**`http://127.0.0.1:8787`** (note **http**, not https — the proxy is plain HTTP
locally; TLS is added by nginx only on the Oracle host). The app allows cleartext
to localhost via `NSAllowsLocalNetworking`, so this works on the simulator.
On a physical iPhone, `127.0.0.1` is the phone itself — use your Mac's LAN IP
instead (e.g. `http://192.168.1.20:8787`, or `http://Your-Mac.local:8787`), and
start the proxy bound to all interfaces so the phone can reach it:

```bash
HOST=0.0.0.0 PROVIDER=mock PORT=8787 npm start
ipconfig getifaddr en0        # your Mac's LAN IP
```

iOS asks once for Local Network access — tap Allow. The app accepts plain http
only for localhost, `*.local`, and private LAN addresses (10/8, 172.16/12,
192.168/16). Device/App Store use needs the HTTPS domain (see below).

### Fixing the Wine-Searcher field mapping

Their exact response schema isn't public, so run once with `DEBUG_UPSTREAM=1`:

```bash
PROVIDER=winesearcher DEBUG_UPSTREAM=1 WS_API_URL=... WS_API_KEY=... npm start
curl -s "http://127.0.0.1:8787/valuation?q=Opus%20One&vintage=2018" | jq ._raw
```

`_raw` is the untouched provider JSON. Compare it to the mapped fields and edit
the paths marked `ADJUST` in `server.js`. Turn `DEBUG_UPSTREAM` off for production.

## The contract it serves

```
GET /valuation?lwin={lwin11}&q={producer name}&vintage={year}&currency=USD
Authorization: Bearer <PROXY_TOKEN>        # required only if PROXY_TOKEN is set
→ { "average":189.0, "min":165.0, "max":220.0, "currency":"USD", "score":95,
    "offers":[ {"merchant":"…","price":175.0,"currency":"USD","url":"https://…",
                "address":"…","latitude":41.0,"longitude":-73.7,"inStock":true} ] }
```

`score` is the critic/community rating (0–100) the app shows per wine. Offers are
sorted cheapest-first **in the app**, so order here doesn't matter.

## Deploy on your Oracle host (Ubuntu + nginx + Let's Encrypt)

```bash
# 1. Code + deps
sudo mkdir -p /opt/cellar-proxy
sudo rsync -a proxy/ /opt/cellar-proxy/     # or git clone just this dir
cd /opt/cellar-proxy && sudo npm ci --omit=dev

# 2. Dedicated user
sudo useradd -r -s /usr/sbin/nologin cellar
sudo chown -R cellar:cellar /opt/cellar-proxy

# 3. Secrets in a root-owned env file (NOT in git)
sudo tee /etc/cellar-proxy.env >/dev/null <<'EOF'
HOST=127.0.0.1
PORT=8787
PROVIDER=winesearcher
PROXY_TOKEN=<openssl rand -hex 32>
WS_API_URL=<from your Wine-Searcher API docs>
WS_API_KEY=<your key>
EOF
sudo chmod 600 /etc/cellar-proxy.env

# 4. systemd
sudo cp proxy/deploy/cellar-proxy.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now cellar-proxy
curl http://127.0.0.1:8787/health           # {"ok":true,...}

# 5. TLS (App Store requires HTTPS; App Transport Security blocks plain HTTP)
sudo cp proxy/deploy/nginx-cellar.conf /etc/nginx/sites-available/cellar
sudo ln -s /etc/nginx/sites-available/cellar /etc/nginx/sites-enabled/
#   edit server_name to your domain, then:
sudo certbot --nginx -d wine.example.com
sudo nginx -t && sudo systemctl reload nginx
```

**Oracle Cloud specifics:** open 443 (and 80 for the ACME challenge) in BOTH the
VCN **Security List / NSG ingress** AND the instance firewall
(`sudo iptables -I INPUT -p tcp --dport 443 -j ACCEPT` or the `firewalld`
equivalent — Oracle images ship with a restrictive iptables by default). Point a
DNS A record at the instance's public IP first, or certbot's challenge fails.

Then in the app: **Settings → endpoint** = `https://wine.example.com`,
**API key** = the `PROXY_TOKEN` value. The Wine-Searcher key stays only on the
server.

## Deploy with Docker behind an existing Caddy

If the host already runs Caddy in Docker (as the Oracle Nextcloud box does),
skip systemd/nginx and run the proxy as a container on Caddy's network:

1. `rsync -az --exclude node_modules --exclude deploy proxy/ <host>:cellar-proxy/app/`
2. Copy `deploy/docker-compose.yml` to `~/cellar-proxy/`, adjust `user:` and the
   network name, create `.env` (see the file header), install deps, `up -d`.
3. Point the domain's A record at the server, append `deploy/Caddyfile.snippet`
   (with your domain) to the Caddyfile, then validate and reload Caddy.
4. Check: `curl https://<domain>/health` → `{"ok":true,...}`

Then in the app: **Settings → endpoint** = `https://<domain>`, **API key** = the
`PROXY_TOKEN` from `.env`.

## Switching providers

- `PROVIDER=mock` — no keys, fake-but-shaped data. Good for wiring/testing.
- `PROVIDER=winesearcher` — set `WS_API_URL` + `WS_API_KEY`. **Confirm the
  request params and response field names against your Wine-Searcher API docs**
  and adjust the mapping marked `ADJUST` in `server.js` — their exact schema
  isn't public, so the adapter maps common field names best-effort.
- `PROVIDER=apify` — set `APIFY_TOKEN`. Runs two actors in parallel and merges
  them; neither needs Apify residential proxies, so both work on the free plan:
  - `mrbridge~vivino-wine-data-scraper` (`APIFY_ACTOR`, ~$0.003/wine, ~20 s) for
    the retail price, community rating and label image. The proxy sends the
    producer + cuvée (plus the vintage when known) and, for a longer name, a
    producer-only variant in the same run — Vivino's own names often differ from
    the label ("Yellow Label" is listed as "Carte Jaune"), and an unmatched query
    returns a placeholder row named "Not found". It ranks candidates by the
    actor's `matchScore` with an exact vintage match on top, breaking ties by
    rating count, scales 700 mL / 750 mL / 1 L prices to a standard bottle, drops
    formats that don't scale (half bottles, magnums), and maps Vivino's 1–5
    rating onto the app's 100-point score.
  - `mrbridge~wine-searcher-scraper-from-list` (`APIFY_WS_ACTOR`, ~80 s) for the
    aggregated **critic** score and the cheapest listing on the market, already
    converted to the requested currency. Set it to `""` to switch this half off.

  The merge: Vivino's asking price becomes `average` (what a bottle is worth),
  Wine-Searcher's cheapest becomes `min` plus a merchant offer, and its critic
  score wins over a community star average.

  **A lookup never waits for the slow half.** Once Vivino answers (~20–30 s),
  Wine-Searcher gets only `WS_GRACE_SECONDS` (default 6 — it's often already
  warm) before the response goes out without it. It keeps running up to
  `WS_TIMEOUT_SECONDS` (default 110) in the background, and when it lands its
  critic score and cheapest price are merged into the cached entry, so the next
  request — or the app's next refresh — gets them instantly. Measured: a cold
  lookup returns in ~28 s, and the same wine 100 s later returns in 69 ms with
  the score upgraded and the merchant offer added. With nothing to show (Vivino
  found nothing) the lookup waits the full timeout instead.

  `max` stays empty (neither actor quotes a range) and online offers are thin;
  nearby stores come from MapKit on the phone. Repeats are cached for 7 days.

  Not `abotapi~wine-searcher-scraper`: its own README says Wine-Searcher accepts
  only residential connections, so it needs Apify Residential (Starter plan or
  higher) and fails every lookup on the free plan with an HTTP 400.

## Security notes

- Provider key only in `/etc/cellar-proxy.env` (0600, root-owned); never logged
  (errors are generic), never sent to the app, never in the query string the app
  sees.
- App→proxy auth is a bearer token compared in constant time; rotate it to cut
  off a leaked build without touching the provider key.
- Runs as an unprivileged user, hardened systemd unit, bound to localhost behind
  nginx TLS.
- Rate limit (default 60/min/IP) + 7-day cache cap provider spend.
