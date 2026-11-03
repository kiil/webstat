# Today's figures and a history per day, folded from `webstat.<site>.*`.
#
# The actor keeps today's tallies per site in its state and writes a summary
# of every site to `webstat-stats.out` (ttl last:1, `sites.<site>`) after
# every new event, and once when a replay is done, so the dashboard reads one
# frame. The day comes from the frame's meta (set by the server in
# Copenhagen time), so a replay from the first frame gives the same result.
# When an event from a new day arrives, today moves into the history (the
# last 400 days are kept, each with its views, visitors, top five articles,
# clicks and prints).
#
# Events: pageview (counts, titles, referrers, feed), read (50/100 percent of
# an article), leave (seconds visible, the latest per page view), click (a
# support or subscription link, or a download). A click whose target is under
# /print/ ("Udskriv som PDF" on klimaleksikon.dk) is a print, counted apart
# from the other clicks by the page it was printed from. It also keeps the last hour of page views
# as {path, ts, ref} (`recent`), from which the server scores what is hot;
# views without `ts` (before the server stamped them) are left out.
{
  run: {|frame, state = {}|
    # The latest summary of every site, as kept in the state.
    let summaries = {|sites| $sites | transpose name s | where {|r| $r.s.out != null } | reduce -f {} {|r, acc| $acc | insert $r.name $r.s.out } }
    # The replay is done: write the summary once, now that it is complete.
    if $frame.topic == "xs.threshold" {
      let sites = ($state | get -o sites | default {})
      if ($sites | is-empty) { return {next: $state} }
      return {out: {updated: $frame.id, sites: (do $summaries $sites)}, next: $state}
    }
    let p = ($frame.topic | split row ".")
    let kind = ($p | last)
    if ($p | length) != 3 or ($p | first) != "webstat" or $kind not-in [pageview read leave click] {
      return {next: $state}
    }
    let m = ($frame.meta? | default {})
    let day = ($m | get -o day | default "")
    if $day == "" { return {next: $state} }
    let site = ($p | get 1)

    # One site's step: its state and the event in, {out?, next} back. It is
    # defined here because the actor's engine sees nothing outside `run`.
    let fold = {|frame, kind, m, day, state|
      let blank = {day: $day, views: 0, visitors: {}, paths: {}, titles: {}, refs: {}, devices: {}, browsers: {}, systems: {}, types: {}, read50: {}, read100: {}, leaves: {}, clicks: {}, clicks_from: {}, prints: {}, subscribe_from: {}}
      # Fill keys a state from an older version of this actor lacks.
      let current = ($blank | merge ($state | get -o today | default {}))
      let history = ($state | get -o history | default {})

      # An event from a day already closed only adds a page view to that day.
      if $day < $current.day {
        if $kind != "pageview" { return {next: $state} }
        let old = ($history | get -o $day | default {views: 0, visitors: 0})
        return {next: ($state | upsert history ($history | upsert $day ($old | upsert views ($old.views + 1))))}
      }

      let top = {|r: record, n: int| $r | transpose name views | sort-by views --reverse | first $n }
      let bump = {|r: record, k: any| if $k == null { $r } else { $r | upsert ($k | into string) (($r | get -o ($k | into string) | default 0) + 1) } }

      let rolled = (if $day > $current.day {
        let closed = {
          views: $current.views
          visitors: ($current.visitors | columns | length)
          top: (do $top $current.paths 5 | each {|r| $r | insert title ($current.titles | get -o $r.name) })
          clicks: ($current.clicks | values | reduce -f 0 {|x, acc| $acc + $x })
          prints: ($current.prints | values | reduce -f 0 {|x, acc| $acc + $x })
        }
        {today: $blank, history: ($history | upsert $current.day $closed
          | transpose k v | sort-by k | last 400 | reduce -f {} {|r, acc| $acc | insert $r.k $r.v })}
      } else {
        {today: $current, history: $history}
      })
      let t = $rolled.today
      let path = ($m | get -o path | default "/")
      let ts = ($m | get -o ts)
      let stamped = $kind == "pageview" and ($ts | describe) == "int"

      let kept = ($state | get -o recent | default [])
      let recent = (if not $stamped { $kept } else {
        $kept | where ts > ($ts - 3600) | append {path: $path, ts: $ts, ref: ($m | get -o ref)}
      })
      let earlier = ($state | get -o feed | default [])
      let feed = (if not $stamped { $earlier } else {
        $earlier | prepend {path: $path, title: ($m | get -o title), ref: ($m | get -o ref), device: ($m | get -o device), ts: $ts} | first 15
      })

      let today = (match $kind {
        "pageview" => ($t
          | upsert views ($t.views + 1)
          | upsert visitors (if ($m | get -o visitor) == null { $t.visitors } else { $t.visitors | upsert $m.visitor true })
          | upsert paths (do $bump $t.paths $path)
          | upsert titles (if ($m | get -o title) == null { $t.titles } else { $t.titles | upsert $path $m.title })
          | upsert refs (do $bump $t.refs ($m | get -o ref))
          | upsert devices (do $bump $t.devices ($m | get -o device))
          | upsert browsers (do $bump $t.browsers ($m | get -o browser))
          | upsert systems (do $bump $t.systems ($m | get -o system))
          | upsert types (do $bump $t.types ($m | get -o type))
          | upsert subscribe_from (if $path == "/abonnent" and ($m | get -o from) != null { do $bump $t.subscribe_from $m.from } else { $t.subscribe_from }))
        "read" => (if ($m | get -o depth) == 100 { $t | upsert read100 (do $bump $t.read100 $path) } else { $t | upsert read50 (do $bump $t.read50 $path) })
        "leave" => (if ($m | get -o view) == null { $t } else {
          $t | upsert leaves ($t.leaves | upsert $m.view {path: $path, seconds: $m.seconds})
        })
        "click" => (if ($m | get -o target | default "" | str starts-with "/print/") {
          $t | upsert prints (do $bump $t.prints $path)
        } else {
          $t
          | upsert clicks (do $bump $t.clicks ($m | get -o target))
          | upsert clicks_from (do $bump $t.clicks_from $path)
        })
      })

      # Per article (a path with a headline, not the front page): views, the
      # share that read halfway and to the end, median seconds visible and
      # support clicks from it.
      let times = ($today.leaves | values | group-by path)
      let articles = (do $top $today.paths 30
        | where {|r| $r.name != "/" and ($today.titles | get -o $r.name) != null }
        | first 15
        | each {|r|
          let r50 = ($today.read50 | get -o $r.name | default 0)
          let r100 = ($today.read100 | get -o $r.name | default 0)
          let secs = ($times | get -o $r.name | default [] | each {|l| $l.seconds })
          {
            name: $r.name
            title: ($today.titles | get $r.name)
            views: $r.views
            read50: ([(($r50 + $r100) * 100 // $r.views) 100] | math min)
            read100: ([($r100 * 100 // $r.views) 100] | math min)
            median: (if ($secs | is-empty) { null } else { $secs | math median | into int })
            clicks: ($today.clicks_from | get -o $r.name | default 0)
            prints: ($today.prints | get -o $r.name | default 0)
          }
        })

      let titled = {|rows| $rows | each {|r| $r | insert title ($today.titles | get -o $r.name) } }
      let out = {
        updated: ($frame.id)
        today: {
          day: $today.day
          views: $today.views
          visitors: ($today.visitors | columns | length)
          clicks: ($today.clicks | values | reduce -f 0 {|x, acc| $acc + $x })
          paths: (do $titled (do $top $today.paths 20))
          articles: $articles
          titles: $today.titles
          refs: (do $top $today.refs 10)
          devices: (do $top $today.devices 3)
          browsers: (do $top $today.browsers 6)
          systems: (do $top $today.systems 6)
          types: (do $top $today.types 6)
          click_targets: (do $top $today.clicks 6)
          clicks_from: (do $titled (do $top $today.clicks_from 6))
          prints: ($today.prints | values | reduce -f 0 {|x, acc| $acc + $x })
          prints_from: (do $titled (do $top $today.prints 6))
          subscribe_from: (do $titled (do $top $today.subscribe_from 6))
        }
        recent: $recent
        feed: $feed
        history: ($rolled.history | transpose day figures | sort-by day --reverse | first 30
          | each {|r| {visitors: 0, top: [], clicks: 0, prints: 0} | merge $r.figures | insert day $r.day })
      }
      {out: $out, next: {today: $today, history: $rolled.history, recent: $recent, feed: $feed}}
    }

    # Each site folds on its own; `out` carries the latest summary of every
    # site, so the server still reads one frame.
    let sites = ($state | get -o sites | default {})
    let before = ($sites | get -o $site | default {state: {}, out: null})
    let step = (do $fold $frame $kind $m $day $before.state)
    let sites = ($sites | upsert $site {state: $step.next, out: ($step | get -o out | default $before.out)})
    # While the actor replays old frames it writes nothing: one output per
    # replayed frame is thousands of frames at once, which overruns xs's live
    # subscription so the actor never sees a new frame again (seen
    # 2026-11-03). The threshold frame above writes the replay's result.
    let ts = ($m | get -o ts)
    let fresh = ($ts | describe) == "int" and ((date now | into int) // 1_000_000_000) - $ts < 120
    if not $fresh { return {next: {sites: $sites}} }
    {out: {updated: $frame.id, sites: (do $summaries $sites)}, next: {sites: $sites}}
  }

  start: "first"
  return_options: {ttl: "last:1"}
}
