---
name: moonward
description: "Decide whether a call should go ahead, in MoonBit with moonbitstack/moonward: a circuit breaker in the style of Google SRE, adaptive load shedding, an adaptive concurrency limit (AIMD, Vegas, Gradient), token bucket, sliding window and fixed-period limiters, a concurrency gate, retry backoff with jitter, and deadlines. Nothing reads a clock or a random source; the caller passes both. Use when adding retries, rate limits, timeouts or overload protection to a client or a server."
---

# moonward

```bash
moon add moonbitstack/moonward
```

```moonbit
// moon.pkg
import {
  "moonbitstack/moonward",
}
```

Every decision takes `now`, the caller's clock in nanoseconds, and where a decision is a roll, a draw from `[0, 1)`. Durations are moondate `Span`s.

## Retry with backoff

```moonbit
fn retry_waits(draws : Array[Double]) -> Array[Int64] {
  let backoff = @moonward.backoff // 3 attempts, 100 ms doubling to a 1 s cap, spread by a fifth
  let waits = []
  let mut attempt = 0
  while backoff.more(attempt) && attempt < draws.length() {
    waits.push(backoff.delay(attempt, random=draws[attempt]).nanos)
    attempt += 1
  }
  waits
}
```

Change one field and keep the rest: `{ ..@moonward.backoff, attempts: 5 }`, or `Backoff::new(attempts=5)`.

## A circuit breaker around a backend

```moonbit
fn guarded(
  breaker : @moonward.Breaker,
  now : Int64,
  draw : Double,
  call : () -> Bool,
) -> Bool {
  match breaker.allow(now, draw) {
    None => false // refused without trying
    Some(promise) => {
      let ok = call()
      if ok {
        promise.pass(now)
      } else {
        promise.fail(now)
      }
      ok
    }
  }
}
```

There is no open, half-open and closed: the breaker refuses each call with a probability that grows with the recent failures, so a struggling backend keeps getting a trickle of calls and recovers on its own.

## A rate limit

```moonbit
fn admit(bucket : @moonward.Bucket, now : Int64) -> Result[Unit, Int64] {
  if bucket.take(now) {
    Ok(())
  } else {
    Err(bucket.next(now).nanos) // how long until a token lands: a Retry-After
  }
}
```

`Bucket::new(rate, burst=8.0)` takes `rate` tokens a second and holds at most `burst`. `Sliding` counts a quota over any window-long stretch, `Period` over fixed periods, and `Gate` only how many are in flight (`enter`, `leave`).

## A concurrency limit that adapts

```moonbit
fn call_backend(limiter : @moonward.Limiter, now : Int64, done_at : Int64) -> Bool {
  guard limiter.acquire(now) is Some(lease) else { return false }
  lease.pass(done_at) // fail(now) on a timeout or an overload reply, ignore() otherwise
  true
}
```

`Limiter::new()` runs Vegas from a limit of 20; `rule=Gradient(@moonward.gradient)` and `rule=Aimd(@moonward.aimd)` are the others. Settle every lease exactly once, or the limiter counts the call as in flight for ever.

## Things that catch people out

- `now` is nanoseconds. A millisecond clock multiplied by 1 000 000 is fine; seconds are not.
- The draws are yours to supply, so a test replays an exact sequence; in production pass a uniform random number.
- The shedder refuses only when the CPU is hot and more calls are in flight than the server has shown it can finish; pass the CPU use in thousandths to each `allow`.
- A `Deadline` started with `Deadline::start(span, now)` answers `remaining(now)` and `expired(now)`; pass the remainder on to the next call rather than starting a fresh one.
