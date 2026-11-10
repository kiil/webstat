# Where the readers of one article rested and stopped, from the latest
# leave of each view that carries the measurements: per 5 percent band
# of the body (`flow`) the share of readers still reading as the band
# begins and ends, the resting seconds (and heat 0-5) and how many
# readings ended there, and per landmark (video, embed, image, quote,
# table, subheading) how many reached it, the median seconds they spent
# with it in view, how many clicked into it, and how many stopped there.
#
# The stats actor folds today's leaves through this and the server all of an
# article's leaves (/visual). The actor's engine sees nothing outside its
# `run`, so serve.nu writes this file into the actor when it registers it:
# keep it one self-contained command.
export def attention-of [leaves: list]: nothing -> any {
  let pct = {|a: int, b: int| if $b == 0 { null } else { [($a * 100 // $b) 100] | math min } }
  let median = {|xs: list| if ($xs | is-empty) { null } else { $xs | math median | into int } }
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
