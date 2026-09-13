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
instead (e.g. `http://192.168.1.20:8787`). Device/App Store use needs the HTTPS
domain (see below).

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

## Switching providers

- `PROVIDER=mock` — no keys, fake-but-shaped data. Good for wiring/testing.
- `PROVIDER=winesearcher` — set `WS_API_URL` + `WS_API_KEY`. **Confirm the
  request params and response field names against your Wine-Searcher API docs**
  and adjust the mapping marked `ADJUST` in `server.js` — their exact schema
  isn't public, so the adapter maps common field names best-effort.
- `PROVIDER=apify` — set `APIFY_TOKEN` (pay-per-result, ~2.5¢/wine). Adjust the
  actor input/output mapping to the actor you choose.

## Security notes

- Provider key only in `/etc/cellar-proxy.env` (0600, root-owned); never logged
  (errors are generic), never sent to the app, never in the query string the app
  sees.
- App→proxy auth is a bearer token compared in constant time; rotate it to cut
  off a leaked build without touching the provider key.
- Runs as an unprivileged user, hardened systemd unit, bound to localhost behind
  nginx TLS.
- Rate limit (default 60/min/IP) + 7-day cache cap provider spend.
