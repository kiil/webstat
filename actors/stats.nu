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
# an article), leave (seconds visible, the latest per page view, with where
# the reader rested and stopped in the article), click (a support or
# subscription link, or a download), teasers (front page teasers a reader
# had in view for a second), tclick (a click on one of them) and search
# (the words and how many results they gave, counted per word in lower case). A click
# whose target is under /print/ ("Udskriv som PDF" on klimaleksikon.dk) is a
# print, counted apart from the other clicks by the page it was printed from.
# It also keeps the last hour of page views as {path, ts, ref} (`recent`),
# from which the server scores what is hot; views without `ts` (before the
# server stamped them) are left out.
#
# A page view whose `from` is the front page is a front page click: its
# reading (read events and leave by the same view id) is counted per article
# as what the teaser led to.
{
  run: {|frame, state = {}|
    let top = {|r: record, n: int| $r | transpose name views | sort-by views --reverse | first $n }
    let total = {|r: record| $r | values | reduce -f 0 {|x, acc| $acc + $x } }
    let pct = {|a: int, b: int| if $b == 0 { null } else { [($a * 100 // $b) 100] | math min } }
    let median = {|xs: list| if ($xs | is-empty) { null } else { $xs | math median | into int } }

    # Where the readers of one article rested and stopped, from the latest
    # leave of each view that carries the measurements: per 5 percent band
    # of the body (`flow`) the share of readers still reading as the band
    # begins and ends, the resting seconds (and heat 0-5) and how many
    # readings ended there, and per landmark (video, embed, image, quote,
    # table, subheading) how many reached it, the median seconds they spent
    # with it in view, how many clicked into it, and how many stopped there.
    let attention = {|leaves: list|
      let ls = ($leaves | where {|l| ($l.rest? | default null) != null })
      if ($ls | length) < 1 { return null }
      let n = ($ls | length)
      let bands = (0..19 | each {|i| $ls | each {|l| $l.rest | get -o $i | default 0 } | math sum })
      let hottest = ([($bands | math max) 1] | math max)
      # The band each reading ended in: 20 for a finished one, else where
      # the reading line last rested (or the depth, when it never rested).
      let ends = ($ls | each {|l|
        let depth = ($l.depth? | default 0)
        if $depth >= 95 { 20 } else { [(($l.at? | default $depth) // 5) 19] | math min }
      })
      # Share of the readers still in the article at each band boundary
      # (21 values, 100 at the top, the finished share at the bottom).
      let stay = (0..20 | each {|k| ($ends | where {|e| $e >= $k } | length) * 100 // $n })
      let heat = ($bands | each {|b| if $b == 0 { 0 } else { [((($b * 5) + $hottest - 1) // $hottest) 5] | math min } })
      let flow = (0..19 | each {|i|
        {from: ($stay | get $i), to: ($stay | get ($i + 1)), heat: ($heat | get $i), rest: ($bands | get $i), left: ($ends | where {|e| $e == $i } | length)}
      })
      let marks = ($ls | each {|l| $l.marks? | default [] | enumerate | each {|e| {i: $e.index, m: $e.item, depth: ($l.depth? | default 0), at: ($l.at? | default null)} } } | flatten
        | group-by {|r| $r.i | into string }
        | items {|i, rows|
          let first = ($rows | last | get m)
          let pos = ($first | get 1)
          let reached = ($rows | where depth >= $pos)
          let stopped = ($reached | where {|r| $r.depth < 95 and $r.at != null and $r.at >= ($pos - 2) and $r.at <= ($pos + 10) } | length)
          {
            kind: ($first | get 0)
            pos: $pos
            label: ($first | get 2)
            reached: ($reached | length)
            reached_pct: (do $pct ($reached | length) $n)
            dwell: (do $median ($reached | each {|r| $r.m | get 3 }))
            engaged: ($rows | where {|r| ($r.m | get 4) == 1 } | length)
            stopped: $stopped
            stop_pct: (do $pct $stopped ($reached | length))
          }
        }
        | sort-by pos)
      let finished = ($ls | where {|l| ($l.depth? | default 0) >= 95 } | length)
      {
        n: $n
        finished: (do $pct $finished $n)
        flow: $flow
        # The band that loses the most readers, and the next one that is
        # far enough from it for both labels to fit under the river.
        falls: (do {
          let worst = ($flow | enumerate | each {|e| {pos: ($e.index * 5 + 2), pct: ($e.item.from - $e.item.to), left: $e.item.left} }
            | where pct >= 5 | sort-by pct --reverse)
          let first = ($worst | first 1)
          $first | append ($worst | where {|f| ($first | all {|w| ($f.pos - $w.pos | math abs) >= 20 }) } | first 1) | sort-by pos
        })
        marks: $marks
        # The landmark that holds back the most readers who got to it.
        brake: ($marks | where {|k| $k.reached >= 3 and ($k.stop_pct | default 0) >= 20 } | sort-by stop_pct --reverse | get -o 0)
      }
    }

    # One site's summary for the dashboard, from its state.
    let summarize = {|s: record, id: string|
      let today = $s.today
      let titled = {|rows| $rows | each {|r| $r | insert title ($today.titles | get -o $r.name) } }
      let leaves = ($today.leaves | values)
      let by_path = ($leaves | group-by path)

      # Per article (a path with a headline, not the front page): views, the
      # share that read halfway and to the end, median seconds visible and
      # support clicks from it.
      let articles = (do $top $today.paths 30
        | where {|r| $r.name != "/" and ($today.titles | get -o $r.name) != null }
        | first 15
        | each {|r|
          let r50 = ($today.read50 | get -o $r.name | default 0)
          let r100 = ($today.read100 | get -o $r.name | default 0)
          {
            name: $r.name
            title: ($today.titles | get $r.name)
            views: $r.views
            read50: ([(($r50 + $r100) * 100 // $r.views) 100] | math min)
            read100: ([($r100 * 100 // $r.views) 100] | math min)
            median: (do $median ($by_path | get -o $r.name | default [] | each {|l| $l.seconds }))
            clicks: ($today.clicks_from | get -o $r.name | default 0)
            prints: ($today.prints | get -o $r.name | default 0)
          }
        })

      # Attention in the most read articles that have measurements.
      let attended = ($articles | each {|a|
        let at = (do $attention ($by_path | get -o $a.name | default []))
        if $at == null { null } else { {name: $a.name, title: $a.title, views: $a.views} | merge $at }
      } | compact | first 6)

      # Front page teasers: seen (a second in view), clicked, and what the
      # click led to (views arriving from the front page, their reading).
      let front_leaves = ($today.front_views | items {|v, p| $today.leaves | get -o $v } | compact | group-by path)
      let teaser_paths = ($today.teaser_seen | columns | append ($today.tclicks | columns) | uniq)
      let teasers = ($teaser_paths | each {|p|
        let seen = ($today.teaser_seen | get -o $p | default 0)
        let clicks = ($today.tclicks | get -o $p | default 0)
        let arrived = ($today.front_in | get -o $p | default 0)
        let r50 = ($today.front_r50 | get -o $p | default 0)
        let r100 = ($today.front_r100 | get -o $p | default 0)
        let secs = ($front_leaves | get -o $p | default [] | each {|l| $l.seconds })
        {
          name: $p
          title: ($today.titles | get -o $p)
          at: ($today.teaser_at | get -o $p)
          seen: $seen
          clicks: $clicks
          ctr: (if $seen == 0 { null } else { ($clicks * 1000 // $seen) / 10 })
          arrived: $arrived
          read50: (do $pct ($r50 + $r100) $arrived)
          read100: (do $pct $r100 $arrived)
          median: (do $median $secs)
          # Clicks that turned into reading: halfway or a minute with it.
          good: ($front_leaves | get -o $p | default [] | where {|l| ($l.depth? | default 0) >= 50 or $l.seconds >= 60 } | length)
        }
      } | sort-by seen clicks --reverse | first 20)
      let modules = ($today.mod_seen | columns | append ($today.mod_clicks | columns) | uniq | each {|k|
        let seen = ($today.mod_seen | get -o $k | default 0)
        let clicks = ($today.mod_clicks | get -o $k | default 0)
        {mod: $k, seen: $seen, clicks: $clicks, ctr: (if $seen == 0 { null } else { ($clicks * 1000 // $seen) / 10 })}
      } | sort-by mod)

      {
        updated: $id
        today: {
          day: $today.day
          views: $today.views
          visitors: ($today.visitors | columns | length)
          clicks: (do $total $today.clicks)
          paths: (do $titled (do $top $today.paths 20))
          articles: $articles
          attention: $attended
          teasers: $teasers
          modules: $modules
          titles: $today.titles
          refs: (do $top $today.refs 10)
          devices: (do $top $today.devices 3)
          browsers: (do $top $today.browsers 6)
          systems: (do $top $today.systems 6)
          types: (do $top $today.types 6)
          click_targets: (do $top $today.clicks 6)
          clicks_from: (do $titled (do $top $today.clicks_from 6))
          prints: (do $total $today.prints)
          prints_from: (do $titled (do $top $today.prints 6))
          subscribe_from: (do $titled (do $top $today.subscribe_from 6))
          searches: ($today.searches | values | sort-by n --reverse | first 25)
          search_count: ($today.searches | values | reduce -f 0 {|x, acc| $acc + $x.n })
          search_zero: ($today.searches | values | where hits == 0 | reduce -f 0 {|x, acc| $acc + $x.n })
        }
        recent: $s.recent
        feed: $s.feed
        history: ($s.history | transpose day figures | sort-by day --reverse | first 30
          | each {|r| {visitors: 0, top: [], clicks: 0, prints: 0, searches: 0} | merge $r.figures | insert day $r.day })
      }
    }

    # The replay is done: write every site's summary once, now that it is
    # complete.
    if $frame.topic == "xs.threshold" {
      let sites = ($state | get -o sites | default {})
      if ($sites | is-empty) { return {next: $state} }
      let sites = ($sites | items {|name, s| {name: $name, s: ($s | upsert out (do $summarize $s.state $frame.id))} } | reduce -f {} {|r, acc| $acc | insert $r.name $r.s })
      return {out: {updated: $frame.id, sites: ($sites | items {|name, s| {name: $name, out: $s.out} } | reduce -f {} {|r, acc| $acc | insert $r.name $r.out })}, next: {sites: $sites}}
    }
    let p = ($frame.topic | split row ".")
    let kind = ($p | last)
    if ($p | length) != 3 or ($p | first) != "webstat" or $kind not-in [pageview read leave click teasers tclick search] {
      return {next: $state}
    }
    let m = ($frame.meta? | default {})
    let day = ($m | get -o day | default "")
    if $day == "" { return {next: $state} }
    let site = ($p | get 1)

    # One site's step: its state and the event in, the next state back. It
    # is defined here because the actor's engine sees nothing outside `run`.
    let fold = {|kind, m, day, state|
      let blank = {day: $day, views: 0, visitors: {}, paths: {}, titles: {}, refs: {}, devices: {}, browsers: {}, systems: {}, types: {}, read50: {}, read100: {}, leaves: {}, clicks: {}, clicks_from: {}, prints: {}, subscribe_from: {}, teaser_seen: {}, teaser_at: {}, tclicks: {}, mod_seen: {}, mod_clicks: {}, front_views: {}, front_in: {}, front_r50: {}, front_r100: {}, searches: {}}
      # Fill keys a state from an older version of this actor lacks.
      let current = ($blank | merge ($state | get -o today | default {}))
      let history = ($state | get -o history | default {})
      let recent0 = ($state | get -o recent | default [])
      let feed0 = ($state | get -o feed | default [])

      # An event from a day already closed only adds a page view to that day.
      if $day < $current.day {
        if $kind != "pageview" { return ($state | merge {today: $current, history: $history, recent: $recent0, feed: $feed0}) }
        let old = ($history | get -o $day | default {views: 0, visitors: 0})
        return {today: $current, history: ($history | upsert $day ($old | upsert views ($old.views + 1))), recent: $recent0, feed: $feed0}
      }

      let bump = {|r: record, k: any| if $k == null { $r } else { $r | upsert ($k | into string) (($r | get -o ($k | into string) | default 0) + 1) } }

      let rolled = (if $day > $current.day {
        let closed = {
          views: $current.views
          visitors: ($current.visitors | columns | length)
          top: (do $top $current.paths 5 | each {|r| $r | insert title ($current.titles | get -o $r.name) })
          clicks: (do $total $current.clicks)
          prints: (do $total $current.prints)
          searches: ($current.searches | values | reduce -f 0 {|x, acc| $acc + $x.n })
        }
        {today: $blank, history: ($history | upsert $current.day $closed
          | transpose k v | sort-by k | last 400 | reduce -f {} {|r, acc| $acc | insert $r.k $r.v })}
      } else {
        {today: $current, history: $history}
      })
      let t = $rolled.today
      let path = ($m | get -o path | default "/")
      let view = ($m | get -o view)
      let ts = ($m | get -o ts)
      let stamped = $kind == "pageview" and ($ts | describe) == "int"

      let recent = (if not $stamped { $recent0 } else {
        $recent0 | where ts > ($ts - 3600) | append {path: $path, ts: $ts, ref: ($m | get -o ref)}
      })
      let feed = (if not $stamped { $feed0 } else {
        $feed0 | prepend {path: $path, title: ($m | get -o title), ref: ($m | get -o ref), device: ($m | get -o device), ts: $ts} | first 15
      })

      # The view this event belongs to arrived from the front page.
      let fronted = $view != null and ($t.front_views | get -o $view) != null
      # The module a teaser sits in: each showcase place on its own, the
      # other modules as one.
      let modkey = {|mod, pos| if $mod == "f" { $"f($pos)" } else { $mod } }

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
          | upsert subscribe_from (if $path == "/abonnent" and ($m | get -o from) != null { do $bump $t.subscribe_from $m.from } else { $t.subscribe_from })
          | if ($m | get -o from) == "/" and $path != "/" and $view != null {
            upsert front_views ($in.front_views | upsert $view $path) | upsert front_in (do $bump $in.front_in $path)
          } else { $in })
        "read" => (if ($m | get -o depth) == 100 { $t | upsert read100 (do $bump $t.read100 $path) } else { $t | upsert read50 (do $bump $t.read50 $path) }
          | if $fronted { if ($m | get -o depth) == 100 { upsert front_r100 (do $bump $in.front_r100 $path) } else { upsert front_r50 (do $bump $in.front_r50 $path) } } else { $in })
        "leave" => (if $view == null { $t } else {
          $t | upsert leaves ($t.leaves | upsert $view ({path: $path, seconds: $m.seconds} | merge ($m | select -o depth at rest marks | compact)))
        })
        "click" => (if ($m | get -o target | default "" | str starts-with "/print/") {
          $t | upsert prints (do $bump $t.prints $path)
        } else {
          $t
          | upsert clicks (do $bump $t.clicks ($m | get -o target))
          | upsert clicks_from (do $bump $t.clicks_from $path)
        })
        "teasers" => ($m | get -o seen | default [] | reduce -f $t {|s, acc|
          $acc
          | upsert teaser_seen (do $bump $acc.teaser_seen $s.0)
          | upsert teaser_at ($acc.teaser_at | upsert $s.0 $"($s.1)($s.2)")
          | upsert titles (if ($s | get -o 3) == null or ($acc.titles | get -o $s.0) != null { $acc.titles } else { $acc.titles | upsert $s.0 ($s | get 3) })
          | upsert mod_seen (do $bump $acc.mod_seen (do $modkey $s.1 $s.2))
        })
        # The words in lower case are the key; the latest spelling, result
        # count and next page are kept, since the index changes.
        "search" => {
          let k = ($m | get -o q | default "" | str downcase)
          if $k == "" { $t } else {
            let n = ($t.searches | get -o $k | get -o n | default 0)
            $t | upsert searches ($t.searches | upsert $k {q: $m.q, n: ($n + 1), hits: ($m | get -o hits), more: ($m | get -o more | default false)})
          }
        }
        "tclick" => ($t
          | upsert tclicks (do $bump $t.tclicks $m.target)
          | upsert mod_clicks (do $bump $t.mod_clicks (do $modkey $m.mod $m.pos)))
      })

      {today: $today, history: $rolled.history, recent: $recent, feed: $feed}
    }

    # Each site folds on its own; `out` carries the latest summary of every
    # site, so the server still reads one frame.
    let sites = ($state | get -o sites | default {})
    let before = ($sites | get -o $site | default {state: {}, out: null})
    let next = (do $fold $kind $m $day $before.state)
    # While the actor replays old frames it writes nothing and summarizes
    # nothing: one output per replayed frame is thousands of frames at once,
    # which overruns xs's live subscription so the actor never sees a new
    # frame again (seen 2026-11-03). The threshold frame above writes the
    # replay's result.
    let ts = ($m | get -o ts)
    let fresh = ($ts | describe) == "int" and ((date now | into int) // 1_000_000_000) - $ts < 120
    if not $fresh { return {next: {sites: ($sites | upsert $site {state: $next, out: $before.out})}} }
    let sites = ($sites | upsert $site {state: $next, out: (do $summarize $next $frame.id)})
    {out: {updated: $frame.id, sites: ($sites | items {|name, s| {name: $name, out: $s.out} } | where out != null | reduce -f {} {|r, acc| $acc | insert $r.name $r.out })}, next: {sites: $sites}}
  }

  start: "first"
  return_options: {ttl: "last:1"}
}
