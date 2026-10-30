# Spike alerts and the morning report, sent with ntfy.sh to the topic in the
# store's webstat.settings (set with POST /admin/settings). serve.nu
# registers this as xs.service.webstat-alerts and puts
# `const HERE = '<checkout>'` in front of it, so lib.nu and config.nuon are
# read from the deployed checkout.
#
# Once a minute, for each site in config.nuon, it scores the hot list from
# the stats actor's latest output. A path that reaches the site's `spike`
# gets one alert a day (`webstat.alert` frames record what was sent). After
# `report_hour` Copenhagen time it sends one report per site on yesterday
# (`webstat.report` frames record it). Frames from before there were several
# sites carry no `site` and belong to the first.
use ($HERE | path join "lib.nu") *

def notify [cfg: record, title: string, message: string, click?: string] {
  if ($cfg | get -o ntfy) == null { return }
  let body = {topic: $cfg.ntfy, title: $title, message: $message, tags: ["newspaper"]}
  let body = (if $click == null { $body } else { $body | insert click $click })
  http post --content-type application/json "https://ntfy.sh/" ($body | to json) | ignore
}

def sent [topic: string, day: string, site: string, first: string]: nothing -> list {
  .cat -T $topic
  | where {|f| let m = ($f.meta? | default {}); ($m | get -o day) == $day and ($m | get -o site | default $first) == $site }
  | each {|f| $f.meta }
}

def check [] {
  let secret = (try { (.last webstat.settings).meta | default {} } catch { {} })
  let cfg = (open ($HERE | path join "config.nuon") | merge $secret)
  # Without a topic there is nowhere to send, and nothing is recorded as sent.
  if ($cfg | get -o ntfy) == null { return }
  let all = (try { (.last webstat-stats.out).meta | get -o sites | default {} } catch { {} })
  let first = ($cfg.sites | columns | first)
  for site in ($cfg.sites | columns) {
    let s = ($all | get -o $site)
    if $s != null and ($s | get -o today) != null {
      check-site $cfg $site ($cfg.sites | get $site) $s $first
    }
  }
}

def check-site [cfg: record, site: string, conf: record, s: record, first: string] {
  let local = (date now | date to-timezone Europe/Copenhagen)
  let day = ($local | format date "%Y-%m-%d")
  let now = ((date now | into int) // 1_000_000_000)

  # Spikes.
  let alerted = (sent webstat.alert $day $site $first | get -o path | default [])
  let hot = (hot ($s | get -o recent | default []) ($s.today | get -o titles | default {}) $now 10)
  for h in ($hot | where {|h| $h.score >= $conf.spike and $h.name not-in $alerted }) {
    let from = (if $h.ref == null { "" } else { $", mest fra ($h.ref)" })
    notify $cfg $"Tager fart: ($h.title | default $h.name)" $"Score ($h.score), ($h.views) visninger den seneste time($from)." $"($conf.base)($h.name)"
    "" | .append webstat.alert --meta {day: $day, site: $site, path: $h.name, score: $h.score} | ignore
  }

  # Morning report on yesterday.
  let due = ($local | format date "%H" | into int) >= $cfg.report_hour
  let yesterday = ($s | get -o history | default [] | where day < $day | first 1)
  if $due and ($yesterday | is-not-empty) and (sent webstat.report $day $site $first | is-empty) {
    let y = ($yesterday | first)
    let lines = ($y | get -o top | default [] | enumerate | each {|r| $"($r.index + 1). ($r.item.title? | default $r.item.name) \(($r.item.views)\)" } | str join "\n")
    let visitors = (if $y.visitors > 0 { $", ($y.visitors) besøgende" } else { "" })
    notify $cfg $"($conf.name) i går: ($y.views) visninger" $"($y.day): ($y.views) visninger($visitors), ($y.clicks) ($conf.clicks | str downcase).\n\n($lines)" $"https://webstat.kiil.cross.stream/?site=($site)"
    "" | .append webstat.report --meta {day: $day, site: $site, about: $y.day} | ignore
  }
}

{
  run: {||
    loop {
      try { check } catch {|e| print -e $"webstat-alerts: ($e.msg)" }
      sleep 60sec
    }
  }
  return_options: {ttl: "last:1"}
}
