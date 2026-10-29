# Today's figures and a history per day, folded from `webstat.*.pageview`.
#
# The actor keeps today's tallies in its state and writes a summary to
# `webstat-stats.out` (ttl last:1) after every view, so the dashboard reads
# one frame. The day comes from the frame's meta (set by the server in
# Copenhagen time), so a replay from the first frame gives the same result.
# When a view from a new day arrives, today's views and visitors move into
# the history (the last 400 days are kept).
#
# It also keeps the last hour of views as {path, ts} (`recent`), from which
# the server scores what is hot right now; views without `ts` (before the
# server stamped them) are left out.
{
  run: {|frame, state = {}|
    let p = ($frame.topic | split row ".")
    if ($p | length) != 3 or ($p | first) != "webstat" or ($p | last) != "pageview" {
      return {next: $state}
    }
    let m = ($frame.meta? | default {})
    let day = ($m | get -o day | default "")
    if $day == "" { return {next: $state} }

    let blank = {day: $day, site: ($p | get 1), views: 0, visitors: {}, paths: {}, titles: {}, refs: {}, devices: {}, browsers: {}, systems: {}, types: {}}
    let current = ($state | get -o today | default $blank)
    let history = ($state | get -o history | default {})

    # A view from a day already closed only adds to that day's count.
    if $day < $current.day {
      let old = ($history | get -o $day | default {views: 0, visitors: 0})
      return {next: ($state | upsert history ($history | upsert $day ($old | upsert views ($old.views + 1))))}
    }

    let rolled = (if $day > $current.day {
      {today: $blank, history: ($history | upsert $current.day {views: $current.views, visitors: ($current.visitors | columns | length)}
        | transpose k v | sort-by k | last 400 | reduce -f {} {|r, acc| $acc | insert $r.k $r.v })}
    } else {
      {today: $current, history: $history}
    })

    let ts = ($m | get -o ts)
    let kept = ($state | get -o recent | default [])
    let recent = (if ($ts | describe) != "int" { $kept } else {
      $kept | where ts > ($ts - 3600) | append {path: ($m | get -o path | default "/"), ts: $ts}
    })

    let bump = {|r: record, k: any| if $k == null { $r } else { $r | upsert ($k | into string) (($r | get -o ($k | into string) | default 0) + 1) } }
    let t = $rolled.today
    let today = ($t
      | upsert views ($t.views + 1)
      | upsert visitors (if ($m | get -o visitor) == null { $t.visitors } else { $t.visitors | upsert $m.visitor true })
      | upsert paths (do $bump $t.paths $m.path?)
      | upsert refs (do $bump $t.refs $m.ref?)
      | upsert devices (do $bump $t.devices $m.device?)
      | upsert browsers (do $bump $t.browsers $m.browser?)
      | upsert systems (do $bump $t.systems $m.system?)
      | upsert types (do $bump $t.types $m.type?))

    let top = {|r: record, n: int| $r | transpose name views | sort-by views --reverse | first $n }
    let out = {
      updated: ($frame.id)
      today: {
        day: $today.day
        views: $today.views
        visitors: ($today.visitors | columns | length)
        paths: (do $top $today.paths 20)
        refs: (do $top $today.refs 10)
        devices: (do $top $today.devices 3)
        browsers: (do $top $today.browsers 6)
        systems: (do $top $today.systems 6)
        types: (do $top $today.types 6)
      }
      recent: $recent
      history: ($rolled.history | transpose day figures | sort-by day --reverse | first 30
        | each {|r| {day: $r.day, views: $r.figures.views, visitors: $r.figures.visitors} })
    }
    {out: $out, next: {today: $today, history: $rolled.history, recent: $recent}}
  }

  start: "first"
  return_options: {ttl: "last:1"}
}
