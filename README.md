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
| `services/alerts.nu` | the morning report and articles taking off, as pushes to the installed app |
| `templates/page.html`, `templates/board.html`, `templates/overview.html` | the dashboard shell and the region `#board` that Datastar patches (minijinja): one site, or all of them |
| `beacon.js` | the script for folkets.dk's palette block |
| `config.nuon` | the sites (origins, link base, name, spike threshold, what clicks count) and the report hour (no secrets) |
| `secrets.nuon` | local only, gitignored: the collector key, sent once with `POST /admin/settings` |

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

## Setting it up on your own sites

webstat is one http-nu handler over an xs store; nothing in it is tied to
Drupal. To run your own: deploy this repo (on cross.stream, or locally as in
[Run](#run)), list your sites in `config.nuon`, and set the key with
`POST /admin/settings` (see [Secrets](#secrets)). Then each site needs two
things: a **beacon** in its pages and, where the platform allows it, a
**collector**.

There are two ways for a beacon to reach webstat:

| | First-party collector (`/nyt.php`) | Straight to `/hit` |
| --- | --- | --- |
| Needs | server code on the site's own domain (PHP, a Worker, an edge function) | only a `<script>` in the page |
| Visitors counted | yes: the collector sends the reader's IP with the key | no: webstat only sees its own proxy's address |
| Ad blockers | leave it alone (same domain) | may block requests to another host |
| Fits | WordPress, Drupal, any PHP host; static sites behind Cloudflare/Netlify/Vercel | Shopify, Squarespace, Wix, plain GitHub Pages |

The collector is `sites/docujai/nyt.php`: a plain PHP file, no framework.
Copy it to the site's web root and change three things: `WEBSTAT` (your
webstat's address), `ORIGINS` (the site's origins, as in `config.nuon`) and
where it reads the key (keep the key file outside the web root). It answers
the browser with 204 at once and forwards the body to `/hit` with
`X-Webstat-Key` and `X-Webstat-Ip`, giving up after a second.

The beacon posts small JSON bodies as `text/plain` with `sendBeacon` (no CORS
preflight, and they survive the reader leaving). The fields webstat accepts
are in `report` in `serve.nu`; `beacon.js` is the full version (reading depth,
resting heat, landmarks, teasers), and this is the least that gives views,
referrers, devices and time on page:

```html
<script>
(function () {
  if (!navigator.sendBeacon || navigator.webdriver) { return; }
  // '/nyt.php' with a collector, else 'https://<your webstat>/hit'
  var collector = '/nyt.php';
  var view = Math.random().toString(36).slice(2, 10);
  var path = location.pathname;
  function send(data) {
    data.view = view; data.path = path;
    navigator.sendBeacon(collector, new Blob([JSON.stringify(data)], {type: 'text/plain'}));
  }
  var here = location.hostname.replace(/^www\./, '');
  var ref = '';
  try { ref = new URL(document.referrer).hostname.replace(/^www\./, ''); } catch (e) {}
  var h1 = document.querySelector('h1');
  var w = window.innerWidth;
  send({
    kind: 'view',
    title: h1 ? h1.textContent.trim() : null,
    ref: ref && ref !== here ? ref : null,
    device: w < 768 ? 'mobile' : w < 1200 ? 'tablet' : 'desktop',
    lang: document.documentElement.lang || null
  });
  // Seconds visible so far, each time the page is hidden; the latest counts.
  var shown = Date.now(), total = 0;
  document.addEventListener('visibilitychange', function () {
    if (document.visibilityState === 'hidden') {
      total += Date.now() - shown;
      var s = Math.round(total / 1000);
      if (s >= 1) { send({kind: 'leave', seconds: Math.min(s, 7200)}); }
    } else { shown = Date.now(); }
  });
})();
</script>
```

Write the script **inline** in the page, never as a linked file: EasyPrivacy
(on by default in uBlock Origin) blocks scripts by address, `/webstat.js`
among them. Leave logged-in editors out so only readers are counted.

### WordPress

Collector: `nyt.php` in the web root, next to `wp-config.php`. Beacon: a
must-use plugin, which needs no activation and survives theme changes:

```php
<?php
// wp-content/mu-plugins/webstat.php (the beacon script beside it as webstat.js)
add_action('wp_head', function () {
  if (is_user_logged_in()) { return; }
  echo '<script>' . file_get_contents(__DIR__ . '/webstat.js') . '</script>';
});
```

Page caches (WP Rocket, LiteSpeed Cache, W3TC) serve anonymous pages with
the script already in them, which is fine: the beacon runs in the browser.
`ref`/`from` and `title` work as they are; `nid` and `type` stay empty, or
fill them from `body.className` (`postid-123`, `single-post`).

### Drupal

Exactly what `sites/docujai/` is: a small module, `docujai_webstat`, whose
`hook_page_attachments()` writes `js/webstat.js` inline into the head for
anonymous readers outside admin routes, and `nyt.php` in the web root.
Rename the module, adjust the selectors at the top of `webstat.js` (the
title, `.field--name-body`, the links counted as clicks), enable it with
`drush en`. The beacon reads the node id from `drupalSettings`, so
`nid` and `type` come along.

### Shopify

No server code of your own on the shop's domain, so the beacon goes straight
to `https://<your webstat>/hit`. Paste it into `layout/theme.liquid` before
`</head>` (Online Store → Themes → Edit code). Don't use a Customer Events
custom pixel: it runs in a sandboxed iframe on another origin, which
webstat rejects. List both `https://<shop>.myshopify.com` and the custom
domain in `origins`. To count clicks, send `{kind: 'click', target: ...}` from
the add-to-cart or checkout buttons. With the shop behind your own
Cloudflare, a Worker can be the collector instead (see below).

### Squarespace

Code Injection → Header (under the site's developer/advanced settings; it
needs a plan that allows code injection), beacon pointing at
`https://<your webstat>/hit`. List both the `*.squarespace.com` address and
the custom domain in `origins`. The editor shows the site in a frame, so
skip the beacon there (`if (window.top !== window.self) return;`) or your
own editing counts as views. Wix and Webflow are the same: a custom code
block in the head.

### Hugo and other static sites

Put the beacon in a partial included in the head (`layouts/partials/head`
or the theme's hook, e.g. `extend-head.html` in Congo/Blowfish) and inline
it with `{{ (resources.Get "js/webstat.js" | minify).Content | safeJS }}`
inside a `<script>`, so no `/js/webstat.js` file is ever requested. Jekyll,
Eleventy, Astro and Next.js static exports work the same way.

On plain GitHub Pages the beacon has to go straight to `/hit` (that is how
www.kiils.dk does it). Behind Cloudflare, Netlify or Vercel, a few lines of
Worker or edge function on the site's own domain can play `nyt.php`: take the
POST on `/nyt`, answer 204, and forward the body to `/hit` with the key from
an environment secret and the reader's IP (`CF-Connecting-IP`,
`x-nf-client-connection-ip`, `x-real-ip`) in `X-Webstat-Ip`. Then visitors
are counted and ad blockers leave it alone, as on a PHP site.

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

## Install as an app

The page is a PWA, like Janus and Hit: `manifest.webmanifest`, an icon set
under `/icons/` and `sw.js`, all in `public/`. Chrome offers **Install**, iOS
**Føj til hjemmeskærm**, and either way it opens in its own window with no
address bar.

The worker is not a caching layer. It keeps the shell and the last board for
each view, and uses them only when the server cannot be reached. The dot next
to "live" stops pulsing when the browser knows it is offline; when only the
server is down the browser does not know, and the old board still looks live
(the time beside it is when it was rendered). `/hit`, `/api/*`, `/updates` and
`/refresh` are never touched. Everything is network-first, so a new deploy
reaches installed apps by itself; bump `VERSION` in `sw.js` only when the
worker's own caching changes.

## Collectors

On klimaleksikon.dk the module `klimaleksikon_webstat` attaches the beacon
to every page anonymous readers see, and `/nyt.php` forwards as on
folkets.dk with the same key (both sites run on one hosting account). Its
clicks are downloads, the teaching sets' PDFs; "Udskriv som PDF"
(`/print/pdf/node/N`) is counted apart as prints (`prints` in
`config.nuon`). On the search page (`/search/node?keys=...`) the beacon
reports the words and how many results they gave; the board lists today's
searches by count, case ignored, with searches that found nothing in red,
and "Tidligere dage" the number per day. The module writes the beacon inline into the page, as on
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

## Notifications

The installed app can get one short report a morning: yesterday's views per
site, the most read article and the clicks. Press **🔔 Morgenrapport** in the
app (on iOS it is there only once the app is on the home screen). A new
subscriber gets yesterday's report at once, which shows that it works.

A path whose hot score reaches the site's `spike` gets one push a day ("Tager
fart: …", with the views, the main referrer and a link to the article);
`webstat.alert` frames record what was sent. Several found in the same minute
share one push.

They are Web Pushes, sent by `services/alerts.nu`, the report after
`report_hour`. As in Janus a push is empty and signed with `openssl`
(`push.nu`), and the service worker fetches the text from `GET /api/notice`
(the latest `webstat.notice`, else the report), so it needs neither node nor
the Mac. A phone that was offline for both a report and a later alert shows
only the latest. The
VAPID key and the subscriptions live in `$CROSS_STREAM_SITE_STATE`
(`vapid.pem`, `webstat-push.json`), or `./state` locally. A new key kills every
subscription. `webstat.push` records the day it went out. `POST
/api/push/subscribe` takes only the endpoints of the real push services, at
most 20, as it is as open as the dashboard.

## Secrets

The collector key is kept out of git. It lives in the store as `webstat.settings` (ttl last:1), set with

```bash
nu -c 'open secrets.nuon | to json' | curl -sX POST https://webstat.kiil.cross.stream/admin/settings --data-binary @-
```

The first call may set it; after that a call must carry the current key in
`X-Webstat-Key`. Without it webstat still counts views, but no collector is
trusted with the reader's address.

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
| `search` | `q` (the words, at most 100 characters), `hits` (results on the first page, 0 when nothing was found) and `more` (there is a next page): a search on klimaleksikon.dk / climate-encyclopedia.com (`/search/node?keys=`), the first page only |

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
articles, a river from top to bottom: its height is the share of readers
still in the article (a finished reading runs to the end, an unfinished one
ends where the reading line last rested), its redness the resting heat, with
the landmarks pinned across it and the biggest losses labelled underneath.
A landmark that at least three readers reached and
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
`/api/hot`, which the collector on folkets.dk calls, and `/sw.js`,
`/manifest.webmanifest`, `/icons/` and `/api/notice`, which an installed app
and its worker fetch without credentials.
