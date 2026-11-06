# Calculations shared by the handler (serve.nu) and the notification service
# (services/alerts.nu). Pure: no store, no clock, no network.

# Half-life of a view in the hot list, in seconds; after an hour a view no
# longer counts.
export const HOT_HALF_LIFE = 900

# What is hot: every view in the last hour weighs 0.5^(age / half-life),
# summed per path. `titles` maps path to headline.
export def hot [recent: list, titles: record, now: int, n: int = 10]: nothing -> list {
  $recent
  | where {|r| ($now - $r.ts) <= 3600 }
  | group-by path
  | items {|path, views|
    let score = ($views | each {|r| 0.5 ** (([0 ($now - $r.ts)] | math max) / $HOT_HALF_LIFE) } | math sum)
    let refs = ($views | get -o ref | compact | uniq --count | sort-by count --reverse)
    {
      name: $path
      title: ($titles | get -o $path)
      score: ($score | math round --precision 1)
      flames: (flames $score)
      views: ($views | length)
      ref: (if ($refs | is-empty) { null } else { $refs | first | get value })
    }
  }
  | sort-by score --reverse
  | first $n
}

# How hot a score looks: 0 below 0.6 (an ember), then one to five flames.
export def flames [score: number]: nothing -> int {
  if $score < 0.6 { 0 } else if $score < 1.5 { 1 } else if $score < 3 { 2 } else if $score < 6 { 3 } else if $score < 10 { 4 } else { 5 }
}

# Views in the last `seconds`.
export def recent-count [recent: list, now: int, seconds: int]: nothing -> int {
  $recent | where {|r| ($now - $r.ts) <= $seconds } | length
}

# Seconds as "1:05" or "12 s".
export def clock [seconds: any]: nothing -> any {
  if $seconds == null { return null }
  let s = ($seconds | into int)
  if $s < 60 { $"($s) s" } else { $"($s // 60):($s mod 60 | fill -a right -c '0' -w 2)" }
}

# The morning report across all sites: {day, title, body, url}, or null when
# there is no earlier day with views. `sites` is config.nuon's, `all` the
# stats actor's figures per site, `today` a date as text.
export def morning-report [sites: record, all: record, today: string]: nothing -> any {
  let days = ($sites | transpose id conf | each {|r|
    let y = ($all | get -o $r.id | get -o history | default [] | where day < $today | first 1 | get -o 0)
    if $y == null or ($y.views? | default 0) == 0 { null } else { $y | insert name $r.conf.name | insert label $r.conf.clicks }
  } | compact)
  if ($days | is-empty) { return null }
  let day = ($days | get day | math max)
  let shown = ($days | where day == $day | sort-by views --reverse)
  let top = ($shown | each {|y| $y | get -o top | default [] } | flatten | where name != "/" | sort-by views --reverse | get -o 0)
  let clicks = ($shown | where {|y| ($y.clicks? | default 0) > 0 } | each {|y| $"($y.name): ($y.clicks) ($y.label | str downcase)" })
  {
    day: $day
    title: $"I går: ($shown | get views | math sum) visninger"
    body: ([
      ($shown | each {|y| $"($y.name) ($y.views)" } | str join " · ")
      (if $top == null { null } else { $"Mest læst: ($top.title? | default $top.name) \(($top.views)\)" })
      (if ($clicks | is-empty) { null } else { $clicks | str join " · " })
    ] | compact | str join "\n")
    url: "/"
    tag: "webstat-morning"
  }
}

# The notification for articles taking off: the hottest in the title and as
# the link, any others on a line each. `found` holds rows from `hot` with
# `site_name` and `base` added.
export def spike-notice [found: list]: nothing -> record {
  let sorted = ($found | sort-by score --reverse)
  let top = ($sorted | first)
  let from = (if $top.ref == null { "" } else { $", mest fra ($top.ref)" })
  {
    title: $"Tager fart: ($top.title | default $top.name)"
    body: ([$"($top.site_name): ($top.views) visninger den seneste time($from)."]
      | append ($sorted | skip 1 | each {|h| $"Også: ($h.title | default $h.name)" })
      | str join "\n")
    url: $"($top.base)($top.name)"
    tag: "webstat-spike"
  }
}
