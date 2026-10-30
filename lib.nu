# Calculations shared by the handler (serve.nu) and the alerts service
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
