// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A token bucket: `rate` tokens accrue per second up to `burst`, and each request
/// takes one.
///
/// It is the rate limiter that allows a burst after a quiet period, which is what
/// a limit on a human-facing API wants — nobody should be refused for making two
/// requests in the same second after an hour of making none.
///
/// Time is nanoseconds from the caller's clock, as everywhere in this package.
pub struct Bucket {
  rate : Double
  burst : Double
  mut tokens : Double
  mut at : Int64
}

///|
/// A bucket that starts full, which is what lets the first burst through.
///
/// `rate` is tokens per second and `burst` is the most it will ever hold. A burst
/// smaller than one means nothing ever passes, so it is raised to one.
pub fn Bucket::new(
  rate : Double,
  burst~ : Double = 0.0,
  now~ : Int64 = 0L,
) -> Bucket {
  let cap = if burst > 0.0 { burst } else if rate > 1.0 { rate } else { 1.0 }
  { rate, burst: cap, tokens: cap, at: now, }
}

///|
/// Whether `n` tokens are available now, taking them if they are.
pub fn Bucket::take(self : Bucket, now : Int64, n~ : Double = 1.0) -> Bool {
  self.fill(now)
  if self.tokens >= n {
    self.tokens = self.tokens - n
    return true
  }
  false
}

///|
/// How long until `n` tokens would be available, without taking them.
///
/// Zero when they are available now. This is what a caller sleeps for rather than
/// spinning, and what a `Retry-After` header is computed from.
pub fn Bucket::next(
  self : Bucket,
  now : Int64,
  n~ : Double = 1.0,
) -> @moondate.Span {
  self.fill(now)
  if self.tokens >= n {
    return @moondate.Span::new()
  }
  if self.rate <= 0.0 {
    // Nothing accrues, so the wait is unbounded; a caller is better told a very
    // long time than a zero it would spin on.
    return @moondate.Span::new(days=365L)
  }
  let short = n - self.tokens
  { nanos: (short / self.rate * 1.0e9).to_int64(), }
}

///|
/// How many tokens are in the bucket, for a caller that reports its own headroom.
pub fn Bucket::tokens(self : Bucket, now : Int64) -> Double {
  self.fill(now)
  self.tokens
}

///|
/// Accrue whatever the elapsed time is worth, up to the burst.
fn Bucket::fill(self : Bucket, now : Int64) -> Unit {
  if now <= self.at {
    return
  }
  let elapsed = (now - self.at).to_double() / 1.0e9
  self.tokens = self.tokens + elapsed * self.rate
  if self.tokens > self.burst {
    self.tokens = self.burst
  }
  self.at = now
}

///|
/// A sliding window counter: at most `quota` events in any `window` long stretch.
///
/// Where a bucket smooths, a window counts. A quota of "a thousand a day" is a
/// window, not a rate, and answering it with a bucket would let a client spend the
/// whole day's allowance in the first minute.
///
/// The stamps of the events in the window are kept, so the count is exact rather
/// than the approximation a two-bucket scheme gives.
pub struct Sliding {
  quota : Int32
  window : @moondate.Span
  stamps : Array[Int64]
}

///|
/// An empty window.
pub fn Sliding::new(quota : Int32, window : @moondate.Span) -> Sliding {
  { quota, window, stamps: [], }
}

///|
/// Whether an event is within the quota now, counting it if it is.
pub fn Sliding::take(self : Sliding, now : Int64) -> Bool {
  self.forget(now)
  if self.stamps.length() < self.quota {
    self.stamps.push(now)
    return true
  }
  false
}

///|
/// How many events remain in the current window.
pub fn Sliding::left(self : Sliding, now : Int64) -> Int32 {
  self.forget(now)
  let used = self.stamps.length()
  if used >= self.quota {
    0
  } else {
    self.quota - used
  }
}

///|
/// When the window will next have room, which is when its oldest event falls out.
pub fn Sliding::next(self : Sliding, now : Int64) -> @moondate.Span {
  self.forget(now)
  if self.stamps.length() < self.quota {
    return @moondate.Span::new()
  }
  let free = self.stamps[0] + self.window.nanos
  if free <= now {
    @moondate.Span::new()
  } else {
    { nanos: free - now, }
  }
}

///|
/// Drop the events that have fallen out of the window.
fn Sliding::forget(self : Sliding, now : Int64) -> Unit {
  let cut = now - self.window.nanos
  self.stamps.retain(stamp => stamp > cut)
}

///|
/// Where a [`Period`] stands after an event: under the quota, exactly on it, or
/// past it.
///
/// The event that hits the quota is still admitted. It is told apart because it is
/// the last one, which is when a caller would warn that the next will be refused.
/// These are go-zero's `Allowed`, `HitQuota` and `OverQuota`.
pub(all) enum Quota {
  Under
  Hit
  Over
} derive(Eq, Debug)

///|
pub extend Quota with Debug::{to_repr}

///|
pub extend Quota with Eq::{not_equal, equal}

///|
/// A fixed window counter: at most `quota` events per `period`, the count starting
/// again when a period ends.
///
/// Cheaper than [`Sliding`], which keeps every stamp, and coarser: a client can
/// spend one quota at the end of a period and another at the start of the next.
/// That is the trade go-zero's `PeriodLimit` makes, and this is it without Redis.
///
/// A period opens on the first event after the last one closed. With `align` it
/// opens on a multiple of `period` on the caller's clock instead, so with a Unix
/// clock a daily quota resets at midnight UTC rather than a day after first use.
pub struct Period {
  quota : Int32
  period : Int64
  align : Bool
  mut start : Int64?
  mut count : Int32
}

///|
/// A counter no event has touched. A period shorter than a nanosecond is raised to
/// one.
pub fn Period::new(
  quota : Int32,
  period : @moondate.Span,
  align~ : Bool = false,
) -> Period {
  {
    quota,
    period: if period.nanos < 1L {
      1L
    } else {
      period.nanos
    },
    align,
    start: None,
    count: 0,
  }
}

///|
/// Count one event at `now` and say where the quota stands.
pub fn Period::take(self : Period, now : Int64) -> Quota {
  self.roll(now)
  if self.start is None {
    self.start = Some(
      if self.align {
        now - (now % self.period + self.period) % self.period
      } else {
        now
      },
    )
  }
  self.count += 1
  if self.count < self.quota {
    Under
  } else if self.count == self.quota {
    Hit
  } else {
    Over
  }
}

///|
/// How many events remain in the current period.
pub fn Period::left(self : Period, now : Int64) -> Int32 {
  self.roll(now)
  if self.count >= self.quota {
    0
  } else {
    self.quota - self.count
  }
}

///|
/// How long until the current period ends. Zero when no period is open, because
/// the next event would open one.
pub fn Period::next(self : Period, now : Int64) -> @moondate.Span {
  self.roll(now)
  match self.start {
    Some(start) => { nanos: start + self.period - now, }
    None => @moondate.Span::new()
  }
}

///|
/// Close the period if `now` is past it. Only an event opens the next one, so
/// asking how much is left does not move where a period starts. A clock that
/// moves backwards stays in the open period rather than earning a fresh quota.
fn Period::roll(self : Period, now : Int64) -> Unit {
  if self.start is Some(start) && now - start >= self.period {
    self.start = None
    self.count = 0
  }
}

///|
/// A count with a ceiling: the concurrency limit a server puts on itself.
///
/// Unlike a rate, this does not depend on time at all — it is how many things are
/// happening at once. A server past its limit answers rather than queues, which is
/// what keeps a queue from becoming the outage.
pub struct Gate {
  limit : Int32
  mut held : Int32
}

///|
/// A gate that nothing has entered.
pub fn Gate::new(limit : Int32) -> Gate {
  { limit, held: 0, }
}

///|
/// Whether there is room, taking it if there is.
pub fn Gate::enter(self : Gate) -> Bool {
  if self.limit > 0 && self.held >= self.limit {
    return false
  }
  self.held = self.held + 1
  true
}

///|
/// Give the room back.
pub fn Gate::leave(self : Gate) -> Unit {
  if self.held > 0 {
    self.held = self.held - 1
  }
}

///|
/// How many are inside.
pub fn Gate::held(self : Gate) -> Int32 {
  self.held
}
