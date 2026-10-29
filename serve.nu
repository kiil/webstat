# webstat: page views from folkets.dk, one event per view, in an xs store.
#
# Deployed by pushing to cross.stream, which reads the features from
# cross-stream.nuon. Locally:
#
#   http-nu :3080 --store ./store --services --datastar serve.nu
#
# POST /hit takes the beacon the site sends on every page view (beacon.js),
# checks it and appends `webstat.<site>.pageview` with the facts in meta. No
# IP address or user agent is stored: the visitor is a hash of IP, user agent
# and a salt that lives in memory for one day, so a visitor can be counted
# once a day and never followed across days.
#
# The actor in actors/stats.nu folds the views into today's figures and a
# history per day; GET / and GET /api/stats read its latest output. The page
# is live: Datastar opens GET /updates, which sends the board as it stands and
# then a new board every time the actor writes new figures.

use http-nu/router *
use http-nu/datastar *

const HERE = (path self .)

# The Datastar bundle: cross.stream says where in $DATASTAR_JS_PATH; local
# http-nu 0.18 serves it here.
const DATASTAR_JS = "/datastar@1.0.4.js"

def datastar-js []: nothing -> string {
  $env.DATASTAR_JS_PATH? | default $DATASTAR_JS
}

# The reader's address: the first X-Forwarded-For entry, else trusted_ip or
# remote_ip. A reader can prepend a made-up address; that only changes how
# their own views are counted as visitors.
def client-ip [req: record]: nothing -> string {
  let forwarded = ($req.headers | get -o x-forwarded-for | default "" | split row "," | first | default "" | str trim)
  if $forwarded != "" { $forwarded } else { $req.trusted_ip? | default ($req.remote_ip? | default "") }
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
} catch {|e|
  print -e $"webstat: could not register the stats actor \(($e.msg)\)"
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

# The beacon's fields, checked and trimmed; null when the body is not a
# usable view. `from json` can hand back a string for garbage, so the type is
# checked, not just caught.
def view []: any -> any {
  let raw = $in
  let parsed = (if ($raw | describe) == "nothing" { null } else { try { $raw | decode utf-8 | from json } catch { try { $raw | from json } catch { null } } })
  if not (($parsed | describe) | str starts-with "record") { return null }
  let path = ($parsed | get -o path | default "" | into string)
  if not ($path starts-with "/") or ($path | str length) > 400 { return null }
  let nid = ($parsed | get -o nid)
  let type = ($parsed | get -o type | default "" | into string)
  let ref = ($parsed | get -o ref | default "" | into string | str downcase)
  let device = ($parsed | get -o device | default "" | into string)
  let lang = ($parsed | get -o lang | default "" | into string)
  {
    path: $path
    nid: (if ($nid | describe) == "int" and $nid > 0 { $nid } else { null })
    type: (if $type =~ '^[a-z_-]{1,40}$' { $type } else { null })
    ref: (if $ref =~ '^[a-z0-9.-]{1,120}$' { $ref } else { null })
    device: (if $device in [mobile tablet desktop] { $device } else { null })
    lang: (if $lang =~ '^[a-z]{2}(-[A-Za-z]{2})?$' { $lang } else { null })
  }
}

def stats []: nothing -> any {
  try { (.last webstat-stats.out).meta } catch { null }
}

# Half-life of a view in the hot list, in seconds; after an hour a view
# no longer counts.
const HOT_HALF_LIFE = 900

# What is hot right now: every view in the last hour weighs 0.5^(age /
# half-life), summed per path. Scored at render time, so the list cools
# between views too.
def hot [recent: list, now: int]: nothing -> list {
  $recent
  | where {|r| ($now - $r.ts) <= 3600 }
  | group-by path
  | items {|path, views|
    let score = ($views | each {|r| 0.5 ** (([0 ($now - $r.ts)] | math max) / $HOT_HALF_LIFE) } | math sum)
    {name: $path, score: ($score | math round --precision 1), views: ($views | length)}
  }
  | sort-by score --reverse
  | first 10
}

# The board region, rendered from the actor's latest figures.
def board []: nothing -> string {
  let s = (stats | default {today: null, history: []})
  let now = ((date now | into int) // 1_000_000_000)
  $s
  | merge {hot: (hot ($s | get -o recent | default []) $now)}
  | merge {rendered: (date now | date to-timezone Europe/Copenhagen | format date "%H:%M:%S")}
  | .mj ($HERE | path join "templates" "board.html")
}

{|req|
  dispatch $req [
    (route {method: "POST", path: "/hit"} {|req ctx|
      # The body first, before anything else touches the pipeline.
      let v = (view)
      let origin = ($req.headers | get -o origin | default "")
      let site = ($SITES | get -o $origin)
      let ua = ($req.headers | get -o user-agent | default "")
      let cors = {"Access-Control-Allow-Origin": $origin, "Vary": "Origin"}
      if $site == null {
        "" | status 403
      } else if $v == null or $ua == "" or ($ua =~ $BOT) or ($req.headers | get -o sec-purpose | default "" | str contains "prefetch") {
        # Not a view worth counting; answer as if it were, so nothing retries.
        "" | status 204 $cors
      } else {
        let day = (today)
        let ip = (client-ip $req)
        let visitor = (if (internal-ip $ip) { null } else { $"(salt $day)|($ip)|($ua)" | hash sha256 | str substring 0..15 })
        let meta = ($v | merge (agent $ua) | merge {day: $day, ts: ((date now | into int) // 1_000_000_000), visitor: $visitor} | compact)
        "" | .append $"webstat.($site).pageview" --meta $meta | ignore
        "" | status 204 $cors
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
        used: (try { client-ip $req } catch {|e| $"error: ($e.msg)" })
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
