# moonward

Resilience for MoonBit without I/O: a circuit breaker, adaptive load shedding, rate limits, quotas, concurrency limits, backoff and deadlines. Every decision is a function of what the caller passes in, so every sequence is reproducible in a test.

```moonbit
let now = 0L // the caller's clock, in nanoseconds
let breaker = @moonward.Breaker::new()
match breaker.allow(now, 0.42) {
  Some(call) => call.pass(now + 30_000_000L) // or call.fail(...)
  None => println("backend refused")
}
let shedder = @moonward.Shedder::new()
match shedder.allow(now, 400) {
  Some(ticket) => ticket.pass(now + 30_000_000L) // or ticket.fail()
  None => println("overloaded")
}
let daily = @moonward.Period::new(1000, @moondate.Span::new(days=1L), align=true)
let quota = daily.take(now) // Under
let rate = @moonward.Bucket::new(100.0, burst=200.0).take(now) // true
let wait = @moonward.backoff.delay(2, random=0.5) // 100 ms
```

`moon run src/examples/tour` puts a failing backend behind a breaker, overloads a server behind a shedder and steps once through each limiter.

## No clock, no dice

Nothing here reads a clock or draws a random number. `now` is whatever the caller's clock read, in nanoseconds; where a decision is a roll, the caller passes a draw from `[0, 1)`; where it depends on CPU, the caller passes the reading in thousandths. Durations are `@moondate.Span`.

A breaker that read the clock itself could only be tested by waiting, and one that drew its own numbers could not be tested at all. Passing both in turns an hour of traffic into a loop over `now`.

## The pieces

|  | What it answers |
|:--:|:--|
| `Breaker` | Whether to call a backend that has been failing, as a probability rather than a switch |
| `Shedder` | Whether this server should take on another call |
| `Bucket` | Whether a call is within a rate, and how long until one would be |
| `Sliding` | Whether it is within a quota counted over any window-long stretch |
| `Period` | The same quota counted per fixed period, cheaper and coarser |
| `Gate` | Whether there is room right now, which has nothing to do with time |
| `Backoff` | How long to wait before trying again, and whether to |
| `Deadline` | How much of a time budget is left |
| `Window[B]` | The rolling window the breaker and the shedder read; any type with a `Default` can be its bucket |

## The breaker

There is no open, half-open and closed. The breaker keeps ten seconds of outcomes and refuses each call with a probability that grows with the failures, so a struggling backend keeps receiving what it can still serve instead of being cut off and then flooded again on recovery. With `accepts` successes out of `total` calls, `failing` the run of all-failure buckets at the head of the window and `working` the run of all-success ones:

$$ w = \max\left(k - (k - floor) \cdot \frac{failing}{size},\ floor\right) $$

$$ drop = \frac{total - protection - w \cdot accepts}{total + 1} \cdot \frac{size - working}{size} $$

With `failing` and `working` at zero this is equation 21-1 of the Google SRE book, *Handling Overload*. The decay of `k`, the recovery factor and the probe that lets one call through after a silent second are go-zero's, from `core/breaker/googlebreaker.go`. A refused call is recorded too, so a breaker that is refusing never reads back as idle.

## The shedder

A call is refused only when the server is both hot and full, which is go-zero's `core/load/adaptiveshedder.go`:

- **hot**: the CPU is at or over the threshold, or was within the last second and the shedder has refused since;
- **full**: both the moving average and the current count of calls in flight exceed what the server has shown it can carry, the busiest bucket's passes per millisecond times the fastest bucket's mean response time, scaled down as the CPU nears 100% but never under a tenth.

A CPU spike with nothing queued refuses nothing, and neither does a queue on an idle CPU.

## Where they run

[moonpool](https://github.com/moonbitstack/moonpool) puts a breaker, a bucket, a backoff and a shedder in front of a resource pool as a `Ward`, so a pool stops connecting to a failing backend and spaces out its reconnections; moondb's connection pool takes the same ward. [moonzero](https://github.com/moonbitstack/moonzero) runs go-zero's breaker, shedder, limiters and timeout middleware on these parts, with go-zero's millisecond clock on the outside.

## Configuration

The breaker and the shedder each take one policy record, with a preset of the same name: `Breaker::new(sre=...)`, `Shedder::new(shed=...)`. A policy is built with `Sre::new(k=2.0)`, or from the preset with `{ ..sre, k: 2.0 }`; the two are the same value. There are no per-call overrides, so there is nothing to rank.

| Preset | Values | Source |
|:--:|:--|:--|
| `sre` | `k` 1.5 decaying to 1.1, protection 5, probe after 1 s, 40 buckets over 10 s | go-zero `googlebreaker.go` |
| `shed` | 50 buckets over 5 s, CPU threshold 900‰, 1 s assumed response time, average weight 0.9, 1 s to cool, never under 0.1 of capacity | go-zero `adaptiveshedder.go` |
| `backoff` | 3 attempts, 100 ms doubling to 1 s, full jitter | gRPC retry policy defaults |

`Period` resets a day after first use unless `align` is set, which is go-zero's `PeriodLimit` default. A `Deadline` with a budget of zero or less never expires, which is how go-zero and gRPC spell no timeout.

## Licence

Apache-2.0. See [LICENSE](LICENSE).
