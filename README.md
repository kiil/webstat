# webstat

Page views, reading depth, time on page and clicks from folkets.dk,
klimaleksikon.dk, www.climate-encyclopedia.com, docujai.com and www.kiils.dk,
as events in an xs store,
served by http-nu at `https://webstat.kiil.cross.stream`. The sites are in
`config.nuon`. The dashboard's front page shows them all side by side
(today's figures, what is hot, the most read, the last 14 days and one live
feed); `/?site=klimaleksikon` shows one site in full.

| File | Role |
| --- | --- |
| `serve.nu` | http-nu handler: `POST /hit` (events), `GET /` (live dashboard), `GET /updates` and `GET /refresh` (Datastar SSE), `GET /api/hot`, `GET /api/stats`, `GET /health`, `GET /whoami`; all but `/hit` take `?site=` |
| `lib.nu` | hot score and small helpers shared by the handler and the service |
| `actors/stats.nu` | folds the events into today's figures and a history per day for each site, written to `webstat-stats.out` (`sites.<site>`) |
| `services/alerts.nu` | spike alerts and the morning report via ntfy |
| `templates/page.html`, `templates/board.html`, `templates/overview.html` | the dashboard shell and the region `#board` that Datastar patches (minijinja): one site, or all of them |
| `beacon.js` | the script for folkets.dk's palette block |
| `config.nuon` | the sites (origins, link base, name, spike threshold, what clicks count) and the report hour (no secrets) |
| `secrets.nuon` | local only, gitignored: the collector key and the ntfy topic, sent once with `POST /admin/settings` |

The collectors live with the sites: folkets.dk's in the folkets repo
(`tools/folkets/site/nyt.php`), klimaleksikon.dk's in the klimaleksikon repo
(`tools/drupal/klimaleksikon_webstat/`, with its beacon), each deployed as
`web/nyt.php`; docujai.com's here in `sites/docujai/` (it has no code repo of
its own). www.kiils.dk is static (Hugo on GitHub Pages) and has no collector:
its beacon (`congo/assets/js/webstat.js` in the `kiil/k` repo,
`~/github-pages/k`) posts straight to `/hit`, so ad blockers may stop some
views and no visitor is counted.

## A new site

Add it to `sites` in `config.nuon` (the origins must match the pages'
`Origin` exactly) and push; a beacon from an origin not listed gets 403.
Then give the site a collector like `nyt.php` that knows the key.

## Run

On cross.stream: push to `main`. `cross-stream.nuon` turns on the store, the
services (the stats actor needs them) and the Datastar bundle; the site is
live at `https://webstat.kiil.cross.stream`.

Locally:

```bash
http-nu :3080 --store ./store --services --datastar serve.nu
```

- Without `--services` the stats actor does not run and the dashboard stays
  empty (the views are still stored).
- Without `--datastar` the page renders once and never updates. The handler
  takes the bundle's path from `$DATASTAR_JS_PATH` and falls back to
  `/datastar@1.0.4.js`, where local http-nu 0.18 serves it.
- The visitor hash uses the first address in `X-Forwarded-For`, else
  `trusted_ip` or `remote_ip`. An internal address (10.x, 192.168.x, loopback
  and the like) gives no visitor. As of 2026-10-29 cross.stream's inner proxy
  overwrites `X-Forwarded-For` with `10.79.0.2` and passes no `remote_ip`, so
  every reader looks the same: views are counted, visitors show "–" until the
  platform passes the reader's address (e.g. `trusted_proxies` on the inner
  Caddy, or `X-Real-IP` set by the outer one). `GET /whoami` shows what
  arrives, for the caller only.
- Keep `./store` out of the directory if you run with `-w`, or the watcher
  reloads on every view.

From the terminal, the nushell module `webstat`
(`~/.config/nushell/modules/webstat`, outside this repo) reads `/api/stats`:
`webstat` for every site today, `webstat top`, `webstat articles`,
`webstat hot`, `webstat feed`, `webstat history`, `webstat by refs`, each
with the site as an argument (`webstat top klimaleksikon`).

Read the raw events with the CLI while the server runs:

```bash
xs cat ./store | jq -c 'select(.topic | startswith("webstat.")) | .meta'
```

## Live dashboard

The page opens `GET /updates`, an SSE stream that sends `#board` as it stands
and then a new `#board` every time the actor writes `webstat-stats.out`, i.e.
on every view. When the page comes back from the background (focus,
visibility, `pageshow`, `online`, and once a minute while visible) it calls
`GET /refresh` for one patch, because a stream can die without an error. If
Caddy buffers responses, turn that off for `/updates` or nothing arrives.

## Collectors

On klimaleksikon.dk the module `klimaleksikon_webstat` attaches the beacon
to every page anonymous readers see, and `/nyt.php` forwards as on
folkets.dk with the same key (both sites run on one hosting account). Its
clicks are downloads, the teaching sets' PDFs; "Udskriv som PDF"
(`/print/pdf/node/N`) is counted apart as prints (`prints` in
`config.nuon`). The module writes the beacon inline into the page, as on
folkets.dk: EasyPrivacy, on in uBlock Origin, blocks any script named
`webstat.js`, so a linked file is never loaded behind an ad blocker.

On docujai.com the module `docujai_webstat` (`sites/docujai/`, deployed to
`public_html/modules/custom/`) does the same, and `public_html/nyt.php`
forwards with the key in `/var/www/docujai.com/.webstat-key`. Clicks are
contact clicks there and on kiils.dk: the contact page, mail and phone.

### folkets.dk

The beacon posts to `/nyt.php` on folkets.dk, not to this host: ad blockers
leave a site's own requests alone, and PHP sees the reader's address
(Cloudflare's `CF-Connecting-IP`), which cross.stream's proxy does not pass
on. `nyt.php` answers 204 at once and forwards the body with
`X-Webstat-Key` (from `~/.folkets-webstat-key` on the folkets server, the same
as the key webstat keeps in its store) and `X-Webstat-Ip`. Only a request with the key may
name the IP. `GET /nyt.php?hot` serves `/api/hot`, cached for a minute, to the
"Hot lige nu" block the beacon builds on the front page.

## Alerts and morning report

`services/alerts.nu` checks every site once a minute. A path whose hot score
reaches the site's `spike` gets one ntfy message a day ("Tager fart: …", with the main referrer
and a link); `webstat.alert` frames record what was sent. After
`report_hour` (Copenhagen) it sends one report on yesterday: views, visitors,
clicks and the top five, one per site (`webstat.report` frames; both kinds
carry `site`, and frames from before that belong to folkets). Subscribe to the
topic in the ntfy app; anyone who knows the topic can read it.

## Secrets

The collector key and the ntfy topic are kept out of git. They live in the
store as `webstat.settings` (ttl last:1), set with

```bash
nu -c 'open secrets.nuon | to json' | curl -sX POST https://webstat.kiil.cross.stream/admin/settings --data-binary @-
```

The first call may set them; after that a call must carry the current key in
`X-Webstat-Key`. Without them webstat still counts views, but no visitor is
recorded and no alert is sent.

## Hot right now

The actor keeps the last hour of views as `{path, ts}` (`recent` in its
output; `ts` is the server's clock in seconds). When the board renders, each
view weighs `0.5 ^ (age / 900)` (a 15-minute half-life) and the weights are
summed per path; the ten highest make "Hot lige nu". The score is computed at
render time, so the list cools between views too, and the page's once-a-minute
refresh keeps it current. `HOT_HALF_LIFE` in `serve.nu` sets the half-life.
The board shows the score as flames (`flames` in `lib.nu`, also in
`/api/hot`): a grey ember below 0.6, then one flame from 0.6, two from 1.5,
three from 3, four from 6 and five from 10; four and five glow and flicker.

## Events

All under `webstat.<site>.`, empty body, the facts in meta; every event has
`path`, `view` (a random id per page view, kept only by the page), `day`
(Copenhagen) and `ts` (Unix seconds), set on the server.

| Topic | Meta |
| --- | --- |
| `pageview` | `title` (the page's h1), `nid`, `type` (`node--type-*`), `ref` (another site's host), `from` (the path on folkets.dk the reader came from), `device` (`mobile` < 768 px, `tablet` < 1200 px, `desktop`), `lang`, `browser`, `system` (coarse, from the user agent), `visitor` |
| `read` | `depth`: 50 when half the article body has been on screen, 100 at 95 percent |
| `leave` | `seconds` the page was visible, sent each time it is hidden; the latest per view counts. On articles also `depth` (percent of the body reached), `at` (where the reading line last rested), `rest` (20 numbers: seconds resting per 5 percent band) and `marks` (landmarks, see below) |
| `click` | `target`: on folkets.dk the path and query of an `/abonnent` or `/stot` link, or `stripe`; on klimaleksikon.dk the path of a PDF or `/print/pdf/node/N`, counted as a print |
| `teasers` | `seen`: front page teasers half in view for a second, `[path, module, place, headline]`; module `f` the showcase, `k` Kort nyt, `a` the archive bands, `u` Ugens eftertragtede, `h` Hot lige nu |
| `tclick` | `target`, `mod`, `pos`: a click on one of those teasers |

`visitor` is the first 16 hex of sha256(salt, IP, user agent), only when
the IP is a public address. The server accepts events only from the origins
in `config.nuon` (others get 403), drops self-declared bots, prefetches and
malformed bodies (204, nothing stored), and stores no IP address or user
agent. The salt lives in http-nu's in-memory `stor` and changes every day.

## Attention and teasers (folkets.dk)

The beacon watches where readers rest in an article, not just how far they
scroll. Once a second, while the page is visible and the reader has moved in
the last 30 seconds (or has clicked into an embed, e.g. to watch a video), a
scroll position that has stood still for 1.2 seconds counts as rest, and the
5 percent band of the body under a reading line 40 percent down the window
gets the second. Landmarks in the body (`v` video, `e` other embed, `i`
image, `q` quote, `t` table, `h` subheading, `a` audio, at most 12) are sent
as `[kind, position percent, label, seconds in the middle of the window
while resting, clicked into 1/0]`; a click into an iframe is seen as the page
losing focus to it.

The board's "Hvor læserne hviler og stopper" draws, for the most read
articles, the resting heat from top to bottom, where unfinished readings
ended, and the landmarks. A landmark that at least three readers reached and
at least 20 percent of them stopped at (ending between 2 points above and 10
below it, without finishing) is named as the brake.

"Fra forsiden til læsning" puts each teaser's views (seen), clicks and CTR
beside what the clicks led to: a page view whose `from` is `/` is a front page
click, and its reads and leave (same view id) give the share that read
halfway or to the end, the median time and "Gode" (halfway or a minute).
CTR per place on the front page (each showcase place, then each module) is
below it. Teasers are measured with an IntersectionObserver, never stored on
the device, and sent in reports under the 4096 bytes `nyt.php` passes on.

## Dashboard access

`GET /` and `GET /api/stats` are open to anyone who knows the address. To
close them, put basic auth in front of everything except `/hit` and
`/api/hot`, which the collector on folkets.dk calls.
