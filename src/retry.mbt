// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// How much randomness goes into a delay.
///
/// A retry with no jitter makes every client that failed together try again
/// together, which is how one outage becomes a second one. `Full`, `Equal` and
/// `Decorrelated` are the strategies AWS's "Exponential Backoff and Jitter"
/// measures; `Spread` is the randomisation factor of Google's client libraries and
/// the one gRPC retries with:
///
/// | | |
/// |:--:|:--|
/// | `Rigid` | the computed delay, unchanged. Reproducible, and it synchronises clients |
/// | `Full` | uniform over `[0, cap]`. The one that spreads clients furthest |
/// | `Equal` | half the cap plus uniform over `[0, cap/2]`. Keeps a floor under the wait |
/// | `Decorrelated` | uniform over `[base, previous × 3]`. Grows from where it last landed rather than from the attempt number |
/// | `Spread(f)` | uniform over `[cap × (1 − f), cap × (1 + f)]`, `f` held to `[0, 1]`. So the wait can pass the cap by `f` |
pub(all) enum Jitter {
  Rigid
  Full
  Equal
  Decorrelated
  Spread(Double)
} derive(Eq, Debug)

///|
pub extend Jitter with Debug::{to_repr}

///|
pub extend Jitter with Eq::{not_equal, equal}

///|
/// When to try again, and how long to wait first.
///
/// The preset is [`backoff`]. Build another with [`Backoff::new`], or update one in
/// place with `{ ..backoff, attempts: 5 }`.
pub(all) struct Backoff {
  base : @moondate.Span
  factor : Double
  cap : @moondate.Span
  attempts : Int32
  jitter : Jitter
} derive(Eq, Debug)

///|
pub extend Backoff with Debug::{to_repr}

///|
pub extend Backoff with Eq::{not_equal, equal}

///|
/// The preset: three attempts, a hundred milliseconds doubling to a one-second
/// ceiling, spread by a fifth either way.
///
/// The schedule is the retry policy gRPC's proposal A6 prints — `initialBackoff`
/// 0.1s, `maxBackoff` 1s, `backoffMultiplier` 2 — and the spread is the
/// `random(0.8, 1.2)` it applies, which grpc-go and grpc-java both draw. Three
/// attempts is the default of the AWS SDKs' standard retry mode.
pub let backoff : Backoff = {
  base: @moondate.Span::new(millis=100L),
  factor: 2.0,
  cap: @moondate.Span::new(seconds=1L),
  attempts: 3,
  jitter: Spread(0.2),
}

///|
/// A backoff by name, every knob with the preset's value.
pub fn Backoff::new(
  base~ : @moondate.Span = backoff.base,
  factor~ : Double = backoff.factor,
  cap~ : @moondate.Span = backoff.cap,
  attempts~ : Int32 = backoff.attempts,
  jitter~ : Jitter = backoff.jitter,
) -> Backoff {
  { base, factor, cap, attempts, jitter, }
}

///|
/// Whether a call that has made `made` attempts may make another.
///
/// The first attempt is 1, so a policy of three attempts allows two retries.
pub fn Backoff::more(self : Backoff, made : Int32) -> Bool {
  made < self.attempts && made >= 0
}

///|
/// The undelayed ceiling before the `retry`-th retry, the first retry being 1:
/// `min(base × factor^(retry-1), cap)`.
///
/// This is what a jitter-free client sleeps and what every other strategy draws
/// within, so it is public: a caller comparing this library against a policy
/// written elsewhere compares this.
pub fn Backoff::ceiling(self : Backoff, retry : Int32) -> @moondate.Span {
  if retry < 1 {
    return @moondate.Span::new()
  }
  let mut nanos = self.base.nanos.to_double()
  for i = 1; i < retry; i = i + 1 {
    nanos = nanos * self.factor
    if nanos >= self.cap.nanos.to_double() {
      return self.cap
    }
  }
  if nanos >= self.cap.nanos.to_double() {
    self.cap
  } else {
    { nanos: nanos.to_int64(), }
  }
}

///|
/// How long to wait before the `retry`-th retry.
///
/// `random` is a value in `[0, 1)` that the caller draws; passing the same one
/// twice gives the same delay twice, which is what makes a retry sequence testable.
/// `previous` is what the last delay turned out to be, which only `Decorrelated`
/// reads — it grows from where it landed rather than from the attempt number.
pub fn Backoff::delay(
  self : Backoff,
  retry : Int32,
  random~ : Double = 0.0,
  previous~ : @moondate.Span = @moondate.Span::new(),
) -> @moondate.Span {
  let ceiling = self.ceiling(retry)
  match self.jitter {
    Rigid => ceiling
    Full => { nanos: (ceiling.nanos.to_double() * clamp(random)).to_int64(), }
    Spread(f) => {
      let f = if f < 0.0 { 0.0 } else if f > 1.0 { 1.0 } else { f }
      let scale = 1.0 - f + 2.0 * f * clamp(random)
      { nanos: (ceiling.nanos.to_double() * scale).to_int64(), }
    }
    Equal => {
      let half = ceiling.nanos / 2L
      { nanos: half + (half.to_double() * clamp(random)).to_int64(), }
    }
    Decorrelated => {
      let low = self.base.nanos
      let high = if previous.nanos <= 0L {
        self.base.nanos * 3L
      } else {
        previous.nanos * 3L
      }
      let top = if high > self.cap.nanos { self.cap.nanos } else { high }
      if top <= low {
        { nanos: low, }
      } else {
        { nanos: low + ((top - low).to_double() * clamp(random)).to_int64(), }
      }
    }
  }
}

///|
/// Every delay a run of retries would wait, for a caller that wants the whole
/// sequence rather than one step — a test, or a log line explaining a plan.
///
/// `randoms` supplies the draws; when it runs short the remaining steps use zero,
/// which is the low end of whatever strategy is in force.
pub fn Backoff::schedule(
  self : Backoff,
  randoms~ : ArrayView[Double] = [][:],
) -> Array[@moondate.Span] {
  let out : Array[@moondate.Span] = []
  let mut previous = @moondate.Span::new()
  for retry = 1; retry < self.attempts; retry = retry + 1 {
    let random = if retry - 1 < randoms.length() {
      randoms[retry - 1]
    } else {
      0.0
    }
    let d = self.delay(retry, random~, previous~)
    out.push(d)
    previous = d
  }
  out
}

///|
/// A draw held to `[0, 1)`, so a caller passing something outside it gets a delay
/// inside the policy rather than one outside it.
fn clamp(v : Double) -> Double {
  if v < 0.0 {
    0.0
  } else if v >= 1.0 {
    0.999999999
  } else {
    v
  }
}
