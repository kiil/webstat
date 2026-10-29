# webstat

Page views from folkets.dk, one event per view, in an xs store, served by
http-nu at `https://webstat.kiil.cross.stream`.

| File | Role |
| --- | --- |
| `serve.nu` | http-nu handler: `POST /hit` (the beacon), `GET /` (live dashboard), `GET /updates` and `GET /refresh` (Datastar SSE), `GET /api/stats`, `GET /health` |
| `actors/stats.nu` | folds `webstat.*.pageview` into today's figures and a history per day, written to `webstat-stats.out` |
| `templates/page.html`, `templates/board.html` | the dashboard shell and the region `#board` that Datastar patches |
| `beacon.js` | the script for folkets.dk's palette block |

## Run

```bash
http-nu :3080 --store ./store --services --datastar --trust-proxy 127.0.0.1/32 serve.nu
```

- `--services` is required: without it the stats actor does not run and the
  dashboard stays empty (the views are still stored).
- `--datastar` serves the bundle the page loads (`/datastar@1.0.4.js` in
  http-nu 0.18); without it the page renders once and never updates.
- `--trust-proxy` must name the proxy in front (Caddy) so `$req.trusted_ip`
  is the reader's address. Without it every reader looks like the proxy and
  the visitor count collapses to one.
- Keep `./store` out of the directory if you run with `-w`, or the watcher
  reloads on every view.

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

## Events

`webstat.<site>.pageview`, empty body, everything in meta:

| Field | From |
| --- | --- |
| `path` | `location.pathname`, decoded |
| `nid`, `type` | Drupal's `drupalSettings.path.currentPath` and the article's `node--type-*` class |
| `ref` | the referrer's host when it is another site |
| `device` | `mobile` (< 768 px), `tablet` (< 1200 px) or `desktop` |
| `lang` | `<html lang>` |
| `browser`, `system` | coarse family from the user agent, on the server |
| `day` | Copenhagen date, on the server |
| `visitor` | first 16 hex of sha256(salt, IP, user agent) |

The server accepts a view only from the origins in `SITES` (others get 403),
drops self-declared bots, prefetches and malformed bodies (204, nothing
stored), and stores no IP address or user agent. The salt lives in http-nu's
in-memory `stor` and changes every day, so a visitor is counted once a day and
cannot be followed across days; a restart starts a new salt, so readers seen
before and after it count twice that day.

## On folkets.dk

Paste `beacon.js` into the `<script>` of the palette block
(`/Users/lk/iwes/folkets/tools/folkets/site/folkets-palette.php`) and run that
script on the site. It sends one `text/plain` beacon per page view (no CORS
preflight, no cookies, nothing stored in the browser). Readers with an ad
blocker or without JavaScript are not counted; `folkets_counter`, which counts
from the access log, remains the cross-check.

The privacy page should say that page views are counted anonymously on our
own server.

## Dashboard access

`GET /` and `GET /api/stats` are open to anyone who knows the address. To
close them, put basic auth in Caddy on everything except `/hit`, which the
readers' browsers must reach.
