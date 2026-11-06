# What the installed app is told, as a Web Push: the morning report across all
# sites, and articles taking off. serve.nu registers this as
# xs.service.webstat-alerts and puts `const HERE = '<checkout>'` in front of
# it, so lib.nu, push.nu and config.nuon are read from the deployed checkout.
#
# Once a minute it looks for something to send. The push itself is empty: the
# text goes in a `webstat.notice` frame first, and the service worker fetches
# it from /api/notice when it wakes. Only a push that arrived counts as sent,
# so a failed one is tried again next minute. Without subscribers nothing is
# sent or recorded.
#
# Morning: after `report_hour` Copenhagen time, once a day (`webstat.push`).
# Taking off: a path reaching its site's `spike` gets one push a day
# (`webstat.alert`). Those found in the same minute share one push, because
# the worker only ever sees the latest notice. Frames from before there were
# several sites carry no `site` and belong to the first.
use ($HERE | path join "lib.nu") *
use ($HERE | path join "push.nu")

# Stores the notice and wakes every subscribed app. True when one arrived.
def notify [notice: record, ttl: int]: nothing -> bool {
  let subs = (push subscriptions)
  if ($subs | is-empty) { return false }
  let meta = ($notice | insert ts ((date now | into int) // 1_000_000_000))
  "" | .append webstat.notice --ttl "last:1" --meta $meta | ignore
  let results = ($subs | each {|e| push send $e --ttl $ttl })
  push forget ($results | where gone | get endpoint)
  $results | any {|r| $r.ok }
}

# True when a report went out on this pass.
def morning [cfg: record, all: record, local: datetime]: nothing -> bool {
  let day = ($local | format date "%Y-%m-%d")
  if ($local | format date "%H" | into int) < $cfg.report_hour { return false }
  if (try { (.last webstat.push).meta.day } catch { null }) == $day { return false }
  let report = (morning-report $cfg.sites $all $day)
  if $report == null { return false }
  if (notify $report 21600) {
    "" | .append webstat.push --ttl "last:1" --meta {day: $day} | ignore
    true
  } else { false }
}

# The paths past their site's spike that have had no push today.
def spikes [cfg: record, all: record, day: string]: nothing -> list {
  let now = ((date now | into int) // 1_000_000_000)
  let first = ($cfg.sites | columns | first)
  let sent = (.cat -T webstat.alert | each {|f| $f.meta? | default {} } | where {|m| ($m | get -o day) == $day })
  $cfg.sites | transpose id conf | each {|r|
    let s = ($all | get -o $r.id | default {})
    let alerted = ($sent | where {|m| ($m | get -o site | default $first) == $r.id } | get -o path | default [])
    hot ($s | get -o recent | default []) ($s | get -o today.titles | default {}) $now 10
    | where {|h| $h.score >= $r.conf.spike and $h.name not-in $alerted }
    | each {|h| $h | insert site $r.id | insert site_name $r.conf.name | insert base $r.conf.base }
  } | flatten
}

def check [] {
  let cfg = (open ($HERE | path join "config.nuon"))
  let all = (try { (.last webstat-stats.out).meta | get -o sites | default {} } catch { {} })
  let local = (date now | date to-timezone Europe/Copenhagen)
  let day = ($local | format date "%Y-%m-%d")
  # One notice a pass: a second would replace the first before a phone reads it.
  if (morning $cfg $all $local) { return }
  let found = (spikes $cfg $all $day)
  if ($found | is-empty) { return }
  if (notify (spike-notice $found) 1800) {
    for h in $found {
      "" | .append webstat.alert --meta {day: $day, site: $h.site, path: $h.name, score: $h.score} | ignore
    }
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
