# SoftDigi AI — self-hosted SearXNG

Infrastructure for the Web Search feature in SoftDigi AI. This is **not**
part of the Flutter app and has no effect on it until deployed and its URL
is passed to a release build. It has not been deployed or tested against
real traffic — review it before going live.

No paid search API, no API key, no per-query billing. SearXNG aggregates
public search engines itself; `redis` here is only SearXNG's own
rate-limit/cache store, not a third-party service.

## Prerequisites

- A server with **root/SSH access and the ability to run Docker** — a VPS,
  not shared/standard web hosting. On Hostinger specifically, this means a
  **VPS (KVM/Cloud VPS) plan**; their regular shared hosting plans cannot run
  Docker or a persistent backend service like this.
- A domain or subdomain (e.g. `search.softdigi.example`) with its DNS **A
  record pointed at the server's public IP** before you start — Caddy's
  automatic HTTPS (Let's Encrypt) needs that to already resolve.
- Ports **80 and 443 open** to the internet on that server (check the
  hosting provider's firewall/security-group settings, not just the OS
  firewall).
- Docker and the Docker Compose plugin installed on the server. On a fresh
  Ubuntu/Debian VPS:
  ```sh
  curl -fsSL https://get.docker.com | sh
  ```
  (installs both `docker` and the `docker compose` plugin).

## Deploy

1. Copy this `deploy/searxng/` folder to the server (`scp -r` or `git clone`
   the repo there).
2. Replace every occurrence of `search.softdigi.example` with your real
   domain in `Caddyfile`, `docker-compose.yml`, and
   `searxng-config/settings.yml`:
   ```sh
   cd deploy/searxng
   grep -rl 'search.softdigi.example' . | xargs sed -i 's/search\.softdigi\.example/YOUR-REAL-DOMAIN/g'
   ```
3. Generate a secret for SearXNG's own session/CSRF protection (not an API
   key, never sent anywhere) and paste it into `searxng-config/settings.yml`
   under `server.secret_key`, replacing the `CHANGE_ME...` placeholder:
   ```sh
   openssl rand -hex 32
   ```
4. `docker compose up -d`
5. Watch the logs for the first minute or two — Caddy needs to successfully
   get a certificate before anything works:
   ```sh
   docker compose logs -f caddy
   ```
6. Confirm the JSON endpoint works, from your own machine (not just the
   server itself, to also prove DNS/firewall are correct):
   `curl "https://YOUR-REAL-DOMAIN/search?q=test&format=json"`
   — should return JSON with a `results` array, not an error about the
   format being disabled, a certificate error, or a connection refusal.
7. Send that working URL (`https://YOUR-REAL-DOMAIN/search`) back — the app
   build itself is a one-line flag once this works:
   ```sh
   flutter build apk --release \
     --dart-define=SEARXNG_ENDPOINT=https://YOUR-REAL-DOMAIN/search
   ```

## Abuse protection

- SearXNG's built-in limiter (`server.limiter: true` in `settings.yml`) rate-
  limits by client without any extra plugin.
- For IP-based limiting at the Caddy layer too, build Caddy with the
  community `caddy-ratelimit` plugin via `xcaddy` — stock `caddy:2-alpine`
  does not include it. See the comment in `Caddyfile`.
- `searxng` is not published on a host port; only `caddy` is, so SearXNG is
  only reachable through the reverse proxy and its HTTPS/headers.

## What the app actually calls

`GET {endpoint}?q=<query>&format=json`, nothing else. No cookies, no
Authorization header, no API key. See
`lib/search/web_search_service.dart` and `lib/search/search_config.dart` in
the main repo for the client and how the endpoint is configured at build
time.

## What this is, versus what's actually been verified

Everything in this folder is a **starting template**, not a verified
production configuration — none of it has been deployed or exercised
against real traffic yet. Specifically unverified, check these first:

- **The limiter may block the app's own JSON requests.** See the long
  comment on `server.limiter` in `settings.yml`. Each phone calls this
  endpoint directly from its own IP; if SearXNG's bot heuristics treat that
  more strictly for `format=json` than for the HTML UI, real users could get
  rate-limited or blocked even under normal use. Test this with a real
  device on a real mobile network before shipping, not just `curl` from the
  server itself.
- **The full SearXNG instance is exposed, not just the JSON path.** The
  Caddyfile reverse-proxies the whole domain to SearXNG — the normal HTML
  search UI is reachable at the same domain, not only `/search?format=json`.
  This is the standard way to run SearXNG (and lets you use the web UI
  yourself to debug), but it does mean anyone who finds the domain can use
  it as a search engine, which is why the limiter and `public_instance:
  false` matter. If you want the HTML UI hidden entirely, that needs
  additional Caddy path-matching rules not written here.
- **The engine list (`google`, `bing`, `duckduckgo`, `wikipedia`) is a
  reasonable default, not a tuned choice.** Public search engines sometimes
  rate-limit or block scraping-style traffic from a given server IP over
  time; which engines stay reliable depends on where this is hosted. Watch
  SearXNG's own logs after deploying for engine errors.
- **The `caddy-ratelimit` plugin is referenced but not built in.** The
  Caddyfile deliberately does not use it (stock Caddy doesn't have it); see
  the comment there if you want IP-based limiting at the proxy layer too.

None of this blocks a correct Flutter-side implementation — the app already
handles a missing, slow, failing, or rate-limited endpoint gracefully (see
`test/search/`). It does mean the Web Search feature should be called
"code-complete," not "production-verified," until these are checked against
a real deployment.
