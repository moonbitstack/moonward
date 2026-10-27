<div align="center">

<h1>moonward</h1>

<p><b>Resilience without I/O.</b><br>
A circuit breaker, adaptive load shedding, four limiters, backoff and a deadline.<br>
Every decision is a function of the numbers you pass in, so every sequence is reproducible.</p>

<p>
<a href="https://moonbitstack.github.io/moonward/"><b>site</b></a> &nbsp;·&nbsp;
<a href="https://moonbitstack.github.io/moonward/guide.html"><b>guide</b></a> &nbsp;·&nbsp;
<a href="https://moonbitstack.github.io/moonward/api.html"><b>API</b></a> &nbsp;·&nbsp;
<a href="https://moonbitstack.github.io/moonward/bay.html"><b>the bay</b></a> &nbsp;·&nbsp;
<a href="https://mooncakes.io/docs/moonbitstack/moonward"><b>mooncakes</b></a>
</p>

</div>

---

## What it is

Nine types that answer one question each: should this call go ahead.

|  | Answers | Refuses when |
|:--|:--|:--|
| **`Breaker`** | Is this backend likely to work? | a draw falls under a refusal fraction built from the last ten seconds of outcomes |
| **`Shedder`** | Should this server take on another call? | the CPU is over its threshold **and** more calls are in flight than the server has shown it can finish |
| **`Bucket`** | Is this call within a rate? | the token is spent; `next` says when the next one lands |
| **`Sliding`** | Is it within a quota over any window-long stretch? | the count reaches the quota |
| **`Period`** | Is it within a quota this period? | the count for the open period is spent |
| **`Gate`** | Is there room right now? | `held` has reached `limit` — it never asks what time it is |
| **`Backoff`** | When to try again, and how long first? | `more(attempts)` is false |
| **`Deadline`** | How much of the budget is left? | `expired` is true |
| **`Window`** | What does the rolling window hold? | never; it is the array of buckets the others read |

## No clock, no dice

Nothing here reads a clock or draws a random number. `now` is whatever your clock read, in nanoseconds; where a decision is a roll, you pass a draw from `[0, 1)`. That is what makes an hour of traffic a loop over `now`, and a retry sequence testable.

```moonbit
let breaker = @moonward.Breaker::new()
let now = 0L
match breaker.allow(now, 0.42) {
  Some(call) => call.pass(now)   // or call.fail(now)
  None => println("refused")
}
```

## The breaker

There is no open, half-open and closed. The breaker keeps ten seconds of outcomes and refuses each call with a probability that grows with the failures in it, so a struggling backend keeps receiving what it can still serve instead of being cut off and then flooded on recovery.

```text
w     = max( k − (k − floor) · failing / size , floor )
drop  = ( total − protection − w · accepts ) / ( total + 1 )
drop ×= ( size − working ) / size
```

`failing` and `working` are runs at the head of the window, not totals. A success pays for `k` calls — at the preset's 1.5, a backend is left alone until more than a third of its calls fail.

## The shedder

A call is refused only when the server is both **hot** and **full**:

- **hot** — the CPU is at or over the threshold, or was within the last second and the shedder has refused since;
- **full** — both the moving average and the current count of calls in flight exceed the busiest bucket's passes per millisecond times the fastest bucket's mean response time, scaled down as the CPU nears 100% but never under a tenth.

A CPU spike with nothing queued refuses nothing, and neither does a long queue on an idle CPU. CPU use is read by you, in thousandths, and passed to each `allow`.

## A run

`moon run src/examples/limiters` offers one burst of forty calls every two seconds to a bucket, a sliding window and a period, all with a quota of twenty a second. The burst straddles the second boundary:

```text
burst  bucket  sliding  period
    0      21       20      40
    1      21       20      40
    2      21       20      40
    3      21       20      40

five tokens in 200 ms
```

The bucket spends a saved burst and then holds the rate. The slide refuses the twenty-first call in any one-second stretch. The period starts a fresh twenty when the second turns over, so the same burst is counted as twenty on each side and all forty pass.

## Presets

Each policy is a record with a preset of the same name. Copy it and change one field — `{ ..sre, k: 2.0 }` — or build it with `Sre::new(k=2.0)`. There are no per-call overrides.

| Preset | Values |
|:--|:--|
| `sre` | `k` 1.5 decaying to 1.1, protection 5, a probe after 1 s, 40 buckets over 10 s |
| `shed` | 50 buckets over 5 s, CPU threshold 900‰, 1 s assumed response time, average weighted 0.9, 1 s to cool, never under 0.1 of capacity |
| `backoff` | 3 attempts, 100 ms doubling to a 1 s cap, each wait spread by a fifth either way |

Durations are `@moondate.Span`, so the package brings `moondate` with it.

## Examples

| Program | What it shows |
|:--|:--|
| [`src/examples/minimal`](src/examples/minimal/main.mbt) | one breaker, one failing backend, four lines of output — the smallest thing that works |
| [`src/examples/limiters`](src/examples/limiters/main.mbt) | the same bursty traffic through all three quotas |
| [`src/examples/tour`](src/examples/tour/main.mbt) | a breaker under an outage, a shedder under rising load, one step through each limiter |
| [`src/examples/guide`](src/examples/guide/main.mbt) | the guide as one program, in the order you read it |

The [bay](https://moonbitstack.github.io/moonward/bay.html) runs the same code compiled to JavaScript, with the knobs on the outside.

## Licence

Apache-2.0. See [LICENSE](LICENSE).
