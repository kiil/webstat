# Spike alerts and the morning report, sent with ntfy.sh to the topic in the
# store's webstat.settings (set with POST /admin/settings). serve.nu
# registers this as xs.service.webstat-alerts and puts
# `const HERE = '<checkout>'` in front of it, so lib.nu and config.nuon are
# read from the deployed checkout.
#
# Once a minute it scores the hot list from the stats actor's latest output.
# A path that reaches `spike` gets one alert a day (`webstat.alert` frames
# record what was sent). After `report_hour` Copenhagen time it sends one
# report on yesterday (`webstat.report` frames record it).
use ($HERE | path join "lib.nu") *

def notify [cfg: record, title: string, message: string, click?: string] {
  if ($cfg | get -o ntfy) == null { return }
  let body = {topic: $cfg.ntfy, title: $title, message: $message, tags: ["newspaper"]}
  let body = (if $click == null { $body } else { $body | insert click $click })
  http post --content-type application/json "https://ntfy.sh/" ($body | to json) | ignore
}

def sent [topic: string, day: string]: nothing -> list {
  .cat -T $topic | where {|f| ($f.meta? | default {} | get -o day) == $day } | each {|f| $f.meta }
}

def check [] {
  let secret = (try { (.last webstat.settings).meta | default {} } catch { {} })
  let cfg = (open ($HERE | path join "config.nuon") | merge $secret)
  # Without a topic there is nowhere to send, and nothing is recorded as sent.
  if ($cfg | get -o ntfy) == null { return }
  let s = (try { (.last webstat-stats.out).meta } catch { null })
  if $s == null or ($s | get -o today) == null { return }
  let local = (date now | date to-timezone Europe/Copenhagen)
  let day = ($local | format date "%Y-%m-%d")
  let now = ((date now | into int) // 1_000_000_000)

  # Spikes.
  let alerted = (sent webstat.alert $day | get -o path | default [])
  let hot = (hot ($s | get -o recent | default []) ($s.today | get -o titles | default {}) $now 10)
  for h in ($hot | where {|h| $h.score >= $cfg.spike and $h.name not-in $alerted }) {
    let from = (if $h.ref == null { "" } else { $", mest fra ($h.ref)" })
    notify $cfg $"Tager fart: ($h.title | default $h.name)" $"Score ($h.score), ($h.views) visninger den seneste time($from)." $"https://www.folkets.dk($h.name)"
    "" | .append webstat.alert --meta {day: $day, path: $h.name, score: $h.score} | ignore
  }

  # Morning report on yesterday.
  let due = ($local | format date "%H" | into int) >= $cfg.report_hour
  let yesterday = ($s | get -o history | default [] | where day < $day | first 1)
  if $due and ($yesterday | is-not-empty) and (sent webstat.report $day | is-empty) {
    let y = ($yesterday | first)
    let lines = ($y | get -o top | default [] | enumerate | each {|r| $"($r.index + 1). ($r.item.title? | default $r.item.name) \(($r.item.views)\)" } | str join "\n")
    let visitors = (if $y.visitors > 0 { $", ($y.visitors) besøgende" } else { "" })
    notify $cfg $"Folkets i går: ($y.views) visninger" $"($y.day): ($y.views) visninger($visitors), ($y.clicks) støtteklik.\n\n($lines)" "https://webstat.kiil.cross.stream/"
    "" | .append webstat.report --meta {day: $day, about: $y.day} | ignore
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
