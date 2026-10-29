# webstat: page views from folkets.dk, as events in an xs store.
#
# Deployed by pushing to cross.stream, which reads the features from
# cross-stream.nuon. Locally:
#
#   http-nu :3080 --store ./store --services --datastar serve.nu
#
# POST /hit takes what the beacon on folkets.dk reports, normally through the
# first-party collector nyt.php on folkets.dk (adblockers leave a site's own
# requests alone, and PHP sees the reader's IP). Four kinds, each its own
# topic under `webstat.<site>.`:
#
#   pageview  a page was opened (path, title, node, referrer, device ...)
#   read      the reader got through 50 or 100 percent of the article
#   leave     seconds the page was visible, sent when it is hidden
#   click     a click on a support or subscription link
#
# No IP address or user agent is stored: the visitor is a hash of IP, user
# agent and a salt that lives in memory for one day, so a visitor can be
# counted once a day and never followed across days.
#
# The actor in actors/stats.nu folds the events into today's figures and a
# history per day; the service in services/alerts.nu sends spike alerts and
# a morning report. The page is live: Datastar opens GET /updates, which sends
# the board as it stands and then a new board every time the actor writes.

use http-nu/router *
use http-nu/datastar *
use ./lib.nu *

const HERE = (path self .)
const CONFIG = (path self ./config.nuon)

# The Datastar bundle: cross.stream says where in $DATASTAR_JS_PATH; local
# http-nu 0.18 serves it here.
const DATASTAR_JS = "/datastar@1.0.4.js"

def datastar-js []: nothing -> string {
  $env.DATASTAR_JS_PATH? | default $DATASTAR_JS
}

# The reader's address. The collector on folkets.dk sends it in X-Webstat-Ip
# with the shared key; a beacon that comes straight from a browser only has
# the first X-Forwarded-For entry, which on cross.stream is the proxy's (see
# internal-ip).
def client-ip [req: record, keyed: bool]: nothing -> string {
  let given = ($req.headers | get -o x-webstat-ip | default "" | str trim)
  let forwarded = ($req.headers | get -o x-forwarded-for | default "" | split row "," | first | default "" | str trim)
  if $keyed and $given != "" { $given } else if $forwarded != "" { $forwarded } else { $req.trusted_ip? | default ($req.remote_ip? | default "") }
}

# An address that says nothing about the reader: empty, loopback or private.
# As of 2026-10-29 cross.stream's inner proxy overwrites X-Forwarded-For with
# the outer proxy's 10.x address and passes no remote_ip, so every reader
# arrives as the same address; hashing it would count everyone as one
# visitor, so no visitor is recorded until the platform passes the real IP.
def internal-ip [ip: string]: nothing -> bool {
  $ip == "" or ($ip =~ '^(10\.|127\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|::1$|f[cd][0-9a-f]{2}:)')
}

# Sites that may send views: origin -> site name in the topic.
const SITES = {
  "https://www.folkets.dk": "folkets"
  "https://folkets.dk": "folkets"
}

# The same self-declared bots folkets_counter drops.
const BOT = '(?i)bot|crawl|spider|slurp|externalhit|externalagent|curl|python|wget|headless|monitor|preview|scan|http|java|okhttp|axios|feed|rss|lighthouse|semrush|ahrefs|gpt|claude|perplexity|bytespider|petal|yandex|baidu'

try {
  (open --raw ($HERE | path join "actors" "stats.nu"))
  | .append xs.actor.webstat-stats.create --ttl "last:1" | ignore
  # The service imports lib.nu and reads config.nuon from this checkout.
  ($"const HERE = '($HERE)'\n" + (open --raw ($HERE | path join "services" "alerts.nu")))
  | .append xs.service.webstat-alerts.create --ttl "last:1" | ignore
} catch {|e|
  print -e $"webstat: could not register the actor and service \(($e.msg)\)"
}

def settings []: nothing -> record { open $CONFIG }

# The secrets: the collector key and the ntfy topic. They live in the store,
# never in git; POST /admin/settings sets them (see the route).
def secrets []: nothing -> record {
  try { (.last webstat.settings).meta | default {} } catch { {} }
}

def status [code: int, headers: record = {}]: any -> any {
  metadata set { merge {'http.response': {status: $code, headers: $headers}} }
}

def today []: nothing -> string {
  date now | date to-timezone Europe/Copenhagen | format date "%Y-%m-%d"
}

# Today's salt, kept in http-nu's in-memory stor only. A restart starts a new
# salt, so a visitor seen before and after a restart counts twice that day.
def salt [day: string]: nothing -> string {
  # `stor create` fails, uncatchably, once the table exists; SQL does not.
  let db = (stor open)
  $db | query db "create table if not exists webstat_salt (day text, salt text)" | ignore
  let found = ($db | query db "select salt from webstat_salt where day = :d" -p {d: $day})
  if ($found | is-empty) {
    let fresh = (random uuid)
    $db | query db "delete from webstat_salt" | ignore
    $db | query db "insert into webstat_salt (day, salt) values (:d, :s)" -p {d: $day, s: $fresh} | ignore
    $fresh
  } else {
    $found | first | get salt
  }
}

# Browser and system from the user agent, coarse enough to say nothing about
# the person.
def agent [ua: string]: nothing -> record {
  let browser = (if ($ua =~ 'Edg/') { "Edge" } else if ($ua =~ 'OPR/|Opera') { "Opera" } else if ($ua =~ 'SamsungBrowser') { "Samsung" } else if ($ua =~ 'Firefox/') { "Firefox" } else if ($ua =~ 'Chrome/|CriOS/') { "Chrome" } else if ($ua =~ 'Safari/') { "Safari" } else { "Andet" })
  let system = (if ($ua =~ 'Android') { "Android" } else if ($ua =~ 'iPhone|iPad|iPod') { "iOS" } else if ($ua =~ 'Windows') { "Windows" } else if ($ua =~ 'Macintosh') { "macOS" } else if ($ua =~ 'Linux|CrOS') { "Linux" } else { "Andet" })
  {browser: $browser, system: $system}
}

# A short text from the beacon, trimmed; null when empty or not a string.
def text [v: any, max: int]: nothing -> any {
  if ($v | describe) != "string" { return null }
  let s = ($v | str replace -ar '\s+' ' ' | str trim)
  if $s == "" { null } else { $s | str substring 0..<($max) }
}

# A path on the site, or null.
def site-path [v: any]: nothing -> any {
  let p = (text $v 400)
  if $p != null and ($p starts-with "/") { $p } else { null }
}

# The beacon's report, checked and trimmed: {kind, meta} or null when it is
# not something to store. `from json` can hand back a string for garbage, so
# the type is checked, not just caught.
def report []: any -> any {
  let raw = $in
  let b = (if ($raw | describe) == "nothing" { null } else { try { $raw | decode utf-8 | from json } catch { try { $raw | from json } catch { null } } })
  if not (($b | describe) | str starts-with "record") { return null }
  let path = (site-path ($b | get -o path))
  if $path == null { return null }
  let view = ($b | get -o view | default "" | into string)
  let common = {path: $path, view: (if $view =~ '^[a-z0-9]{4,16}$' { $view } else { null })}
  let kind = ($b | get -o kind | default "view")
  match $kind {
    "view" => {
      let nid = ($b | get -o nid)
      let type = ($b | get -o type | default "" | into string)
      let ref = ($b | get -o ref | default "" | into string | str downcase)
      let device = ($b | get -o device | default "" | into string)
      let lang = ($b | get -o lang | default "" | into string)
      {kind: "pageview", meta: ($common | merge {
        title: (text ($b | get -o title) 200)
        from: (site-path ($b | get -o from))
        nid: (if ($nid | describe) == "int" and $nid > 0 { $nid } else { null })
        type: (if $type =~ '^[a-z_-]{1,40}$' { $type } else { null })
        ref: (if $ref =~ '^[a-z0-9.-]{1,120}$' { $ref } else { null })
        device: (if $device in [mobile tablet desktop] { $device } else { null })
        lang: (if $lang =~ '^[a-z]{2}(-[A-Za-z]{2})?$' { $lang } else { null })
      })}
    }
    "read" => {
      let depth = ($b | get -o depth)
      if $depth in [50 100] { {kind: "read", meta: ($common | merge {depth: $depth})} } else { null }
    }
    "leave" => {
      let s = ($b | get -o seconds)
      if ($s | describe) == "int" and $s >= 1 and $s <= 7200 { {kind: "leave", meta: ($common | merge {seconds: $s})} } else { null }
    }
    "click" => {
      let target = (text ($b | get -o target) 200)
      if $target != null { {kind: "click", meta: ($common | merge {target: $target})} } else { null }
    }
    _ => null
  }
}

def stats []: nothing -> any {
  try { (.last webstat-stats.out).meta } catch { null }
}

def now-seconds []: nothing -> int { (date now | into int) // 1_000_000_000 }

# The view-model for the board; layout is in templates/board.html.
def board-data []: nothing -> record {
  let s = (stats | default {today: null, history: []})
  let now = (now-seconds)
  let recent = ($s | get -o recent | default [])
  let titles = ($s | get -o today.titles | default {})
  $s | merge {
    hot: (hot $recent $titles $now)
    now: (recent-count $recent $now 300)
    feed: ($s | get -o feed | default [] | each {|f|
      $f | merge {time: ($f.ts * 1_000_000_000 | into datetime | date to-timezone Europe/Copenhagen | format date "%H:%M")}
    })
    articles: ($s | get -o today.articles | default [] | each {|a| $a | merge {time: (clock $a.median)} })
    rendered: (date now | date to-timezone Europe/Copenhagen | format date "%H:%M:%S")
  }
}

def board []: nothing -> string {
  board-data | .mj ($HERE | path join "templates" "board.html")
}

{|req|
  dispatch $req [
    (route {method: "POST", path: "/hit"} {|req ctx|
      # The body first, before anything else touches the pipeline.
      let r = (report)
      let origin = ($req.headers | get -o origin | default "")
      let site = ($SITES | get -o $origin)
      let ua = ($req.headers | get -o user-agent | default "")
      let key = (secrets | get -o key | default "")
      let keyed = $key != "" and (($req.headers | get -o x-webstat-key | default "") == $key)
      let cors = {"Access-Control-Allow-Origin": $origin, "Vary": "Origin"}
      if $site == null {
        "" | status 403
      } else if $r == null or $ua == "" or ($ua =~ $BOT) or ($req.headers | get -o sec-purpose | default "" | str contains "prefetch") {
        # Nothing worth storing; answer as if it were, so nothing retries.
        "" | status 204 $cors
      } else {
        let day = (today)
        let stamp = {day: $day, ts: (now-seconds)}
        let meta = (if $r.kind == "pageview" {
          let ip = (client-ip $req $keyed)
          let visitor = (if (internal-ip $ip) { null } else { $"(salt $day)|($ip)|($ua)" | hash sha256 | str substring 0..15 })
          $r.meta | merge (agent $ua) | merge $stamp | merge {visitor: $visitor}
        } else {
          $r.meta | merge $stamp
        })
        "" | .append $"webstat.($site).($r.kind)" --meta ($meta | compact) | ignore
        "" | status 204 $cors
      }
    })

    # The hot list for folkets.dk's own block (fetched through nyt.php).
    (route {method: "GET", path: "/api/hot"} {|req ctx|
      let s = (stats | default {})
      hot ($s | get -o recent | default []) ($s | get -o today.titles | default {}) (now-seconds) 5
      | where score >= 1
      | to json
      | metadata set { merge {'http.response': {headers: {"Content-Type": "application/json", "Access-Control-Allow-Origin": "*", "Cache-Control": "max-age=60"}}} }
    })

    # Sets the secrets {key, ntfy}. The first time anyone may; after that
    # only a request carrying the current key in X-Webstat-Key. The key must
    # be at least 32 characters.
    (route {method: "POST", path: "/admin/settings"} {|req ctx|
      let raw = $in
      let b = (try { $raw | decode utf-8 | from json } catch { try { $raw | from json } catch { null } })
      let current = (secrets | get -o key | default "")
      let allowed = $current == "" or (($req.headers | get -o x-webstat-key | default "") == $current)
      let key = ($b | get -o key | default "" | into string)
      let ntfy = ($b | get -o ntfy | default "" | into string)
      if not $allowed {
        "" | status 403
      } else if not (($b | describe) | str starts-with "record") or ($key | str length) < 32 or not ($ntfy =~ '^[A-Za-z0-9_-]{8,64}$') {
        "key (32+ characters) and ntfy (a topic name) are required" | status 400 {"Content-Type": "text/plain"}
      } else {
        "" | .append webstat.settings --ttl "last:1" --meta {key: $key, ntfy: $ntfy} | ignore
        "" | status 204
      }
    })

    (route {method: "GET", path: "/api/stats"} {|req ctx|
      stats | default {} | to json | metadata set --content-type "application/json"
    })

    (route {method: "GET", path: "/health"} {|req ctx| "ok" })

    # What the platform tells us about the caller (only ever the caller's own
    # address), to see which header carries the reader's IP behind the proxy.
    (route {method: "GET", path: "/whoami"} {|req ctx|
      {
        used: (try { client-ip $req false } catch {|e| $"error: ($e.msg)" })
        request: ($req | reject -o headers)
        header_names: ($req.headers? | default {} | columns)
        headers: ($req.headers? | default {} | select -o x-forwarded-for x-real-ip forwarded true-client-ip cf-connecting-ip x-client-ip via)
        nu: (version | get version)
      } | to json | metadata set --content-type "application/json"
    })

    # Live feed: the board as it stands at connect time (so a reconnect
    # repairs whatever was missed), then one patch per new figure.
    (route {method: "GET", path: "/updates"} {|req ctx|
      .cat --follow --new -T "webstat-stats.out"
      | each {|f| board | to datastar-patch-elements }
      | prepend (board | to datastar-patch-elements)
      | to sse
    })

    # One patch and done, for a page coming back from the background.
    (route {method: "GET", path: "/refresh"} {|req ctx| board | to datastar-patch-elements | to sse })

    (route {method: "GET", path: "/"} {|req ctx|
      {board: (board), datastar_js: (datastar-js)} | .mj ($HERE | path join "templates" "page.html")
    })

    (route true {|req ctx| "Not found" | status 404 {"Content-Type": "text/plain"} })
  ]
}
