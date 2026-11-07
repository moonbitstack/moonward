// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// One finished call, as a rule sees it.
#derive(Eq, Debug)
pub(all) struct Sample {
  /// How long the call took, in nanoseconds.
  rtt : Int64
  /// Calls in flight when this one started, itself included.
  flying : Int32
  /// Whether the call timed out or was refused further down, which every rule
  /// reads as load to back off from.
  dropped : Bool
}

///|
pub extend Sample with Debug::{to_repr}

///|
pub extend Sample with Eq::{not_equal, equal}

///|
/// How a concurrency limit moves as calls finish.
///
/// The four rules that ship are [`Rule`]'s variants. Implement this to bring your
/// own, and hand it to [`Limiter::custom`].
pub(open) trait Adapt {
  /// The most calls that may be in flight now.
  fn limit(Self) -> Int32
  /// Learn from one finished call.
  fn sample(Self, Sample) -> Unit
}

///|
/// Additive increase, multiplicative decrease: one more while the limit is being
/// used, a fixed share less on a drop or a call slower than the timeout.
///
/// The preset is [`aimd`]. Build another with [`Aimd::new`], or update one in
/// place with `{ ..aimd, max: 500 }`.
#derive(Eq, Debug)
pub(all) struct Aimd {
  /// The limit before any call has finished.
  initial : Int32
  /// The limit never goes under this.
  min : Int32
  /// The limit never goes over this.
  max : Int32
  /// The share of the limit kept after a drop.
  backoff : Double
  /// A call slower than this counts as a drop.
  timeout : @moondate.Span
}

///|
pub extend Aimd with Debug::{to_repr}

///|
pub extend Aimd with Eq::{not_equal, equal}

///|
/// The preset, the same numbers as Netflix concurrency-limits: start at 20, stay
/// within 20 and 200, keep 90% on a drop, and count a call over five seconds as
/// one.
pub let aimd : Aimd = {
  initial: 20,
  min: 20,
  max: 200,
  backoff: 0.9,
  timeout: @moondate.Span::new(seconds=5L),
}

///|
/// A rule by name, every knob with the preset's value.
///
/// # Parameters
/// - `initial` : the limit before any call has finished, `20` in the preset
/// - `min` : the least the limit goes to, `20` in the preset
/// - `max` : the most the limit goes to, `200` in the preset
/// - `backoff` : the share kept after a drop, `0.9` in the preset
/// - `timeout` : a call slower than this counts as a drop, `5 s` in the preset
pub fn Aimd::new(
  initial~ : Int32 = aimd.initial,
  min~ : Int32 = aimd.min,
  max~ : Int32 = aimd.max,
  backoff~ : Double = aimd.backoff,
  timeout~ : @moondate.Span = aimd.timeout,
) -> Aimd {
  { initial, min, max, backoff, timeout, }
}

///|
/// TCP Vegas carried over to requests: the shortest response time seen is the
/// time with no queue, and how far a call's time is over it says how many calls
/// are queued. A short queue grows the limit, a long one shrinks it.
///
/// The thresholds scale with the limit: each is a multiple of the limit's
/// decimal logarithm, rounded down and at least one, so a limit of 10 and one of
/// 10 000 react in proportion.
///
/// The preset is [`vegas`]. Build another with [`Vegas::new`], or update one in
/// place with `{ ..vegas, smoothing: 0.5 }`.
#derive(Eq, Debug)
pub(all) struct Vegas {
  /// The limit before any call has finished.
  initial : Int32
  /// The limit never goes over this.
  max : Int32
  /// How far towards each new estimate the limit moves, from 0 to 1.
  smoothing : Double
  /// Under this many queued calls, times the logarithm, the limit grows by one step.
  alpha : Int32
  /// Over this many queued calls, times the logarithm, the limit shrinks by one step.
  beta : Int32
  /// At or under this many queued calls, times the logarithm, the limit grows by `beta` at once.
  threshold : Int32
  /// How much one step moves the limit, times the logarithm.
  step : Int32
  /// The time with no queue is measured again after about this many calls per
  /// unit of limit, so a slower backend raises the floor it is judged against.
  probe : Int32
}

///|
pub extend Vegas with Debug::{to_repr}

///|
pub extend Vegas with Eq::{not_equal, equal}

///|
/// The preset, the same numbers as Netflix concurrency-limits, whose default rule
/// this is: start at 20, at most 1000, no smoothing, alpha 3, beta 6, threshold
/// and step 1, and a fresh no-queue time every 15 to 30 calls per unit of limit.
pub let vegas : Vegas = {
  initial: 20,
  max: 1000,
  smoothing: 1.0,
  alpha: 3,
  beta: 6,
  threshold: 1,
  step: 1,
  probe: 30,
}

///|
/// A rule by name, every knob with the preset's value.
///
/// # Parameters
/// - `initial` : the limit before any call has finished, `20` in the preset
/// - `max` : the most the limit goes to, `1000` in the preset
/// - `smoothing` : how far towards each new estimate the limit moves, `1.0` in the preset
/// - `alpha` : queued calls under which the limit grows a step, times the logarithm, `3` in the preset
/// - `beta` : queued calls over which the limit shrinks a step, times the logarithm, `6` in the preset
/// - `threshold` : queued calls at or under which the limit grows by `beta`, times the logarithm, `1` in the preset
/// - `step` : one step, times the logarithm, `1` in the preset
/// - `probe` : calls per unit of limit between measurements of the no-queue time, `30` in the preset
pub fn Vegas::new(
  initial~ : Int32 = vegas.initial,
  max~ : Int32 = vegas.max,
  smoothing~ : Double = vegas.smoothing,
  alpha~ : Int32 = vegas.alpha,
  beta~ : Int32 = vegas.beta,
  threshold~ : Int32 = vegas.threshold,
  step~ : Int32 = vegas.step,
  probe~ : Int32 = vegas.probe,
) -> Vegas {
  { initial, max, smoothing, alpha, beta, threshold, step, probe, }
}

///|
/// The gradient between a long-run average response time and the latest one: when
/// calls get slower than usual, the limit shrinks in proportion, and a few slots
/// are always added on top so it can find room to grow.
///
/// The preset is [`gradient`]. Build another with [`Gradient::new`], or update one
/// in place with `{ ..gradient, queue: 8 }`.
#derive(Eq, Debug)
pub(all) struct Gradient {
  /// The limit before any call has finished.
  initial : Int32
  /// The limit never goes under this.
  min : Int32
  /// The limit never goes over this.
  max : Int32
  /// How far towards each new estimate the limit moves, from 0 to 1.
  smoothing : Double
  /// Slots added to every estimate, room for the limit to grow into.
  queue : Int32
  /// Calls the long-run average spans; the first ten are a plain mean.
  window : Int32
  /// How much slower than the long-run average a call may be before the limit shrinks.
  tolerance : Double
}

///|
pub extend Gradient with Debug::{to_repr}

///|
pub extend Gradient with Eq::{not_equal, equal}

///|
/// The preset, the same numbers as Netflix concurrency-limits' second gradient
/// rule: start at 20, stay within 20 and 200, move a fifth of the way, four slots
/// on top, a 600-call average and a tolerance of 1.5.
pub let gradient : Gradient = {
  initial: 20,
  min: 20,
  max: 200,
  smoothing: 0.2,
  queue: 4,
  window: 600,
  tolerance: 1.5,
}

///|
/// A rule by name, every knob with the preset's value.
///
/// # Parameters
/// - `initial` : the limit before any call has finished, `20` in the preset
/// - `min` : the least the limit goes to, `20` in the preset
/// - `max` : the most the limit goes to, `200` in the preset
/// - `smoothing` : how far towards each new estimate the limit moves, `0.2` in the preset
/// - `queue` : slots added to every estimate, `4` in the preset
/// - `window` : calls the long-run average spans, `600` in the preset
/// - `tolerance` : how much slower than the average a call may be, `1.5` in the preset
pub fn Gradient::new(
  initial~ : Int32 = gradient.initial,
  min~ : Int32 = gradient.min,
  max~ : Int32 = gradient.max,
  smoothing~ : Double = gradient.smoothing,
  queue~ : Int32 = gradient.queue,
  window~ : Int32 = gradient.window,
  tolerance~ : Double = gradient.tolerance,
) -> Gradient {
  { initial, min, max, smoothing, queue, window, tolerance, }
}

///|
/// The rules that ship.
#derive(Eq, Debug)
pub(all) enum Rule {
  /// A limit that never moves.
  Fixed(Int32)
  Aimd(Aimd)
  Vegas(Vegas)
  Gradient(Gradient)
}

///|
pub extend Rule with Debug::{to_repr}

///|
pub extend Rule with Eq::{not_equal, equal}

///|
priv struct Still {
  limit : Int32
}

///|
impl Adapt for Still with fn limit(self) {
  self.limit
}

///|
impl Adapt for Still with fn sample(_, _) {

}

///|
priv struct AimdLimit {
  rule : Aimd
  mut limit : Int32
}

///|
impl Adapt for AimdLimit with fn limit(self) {
  self.limit
}

///|
impl Adapt for AimdLimit with fn sample(self, s) {
  let r = self.rule
  let next = if s.dropped || s.rtt > r.timeout.nanos {
    (self.limit.to_double() * r.backoff).to_int()
  } else if s.flying * 2 >= self.limit {
    self.limit + 1
  } else {
    self.limit
  }
  self.limit = next.clamp(min=r.min, max=r.max)
}

///|
/// The decimal logarithm of `n` rounded down, and at least one.
fn log10(n : Int32) -> Int32 {
  let mut k = 0
  let mut m = n
  while m >= 10 {
    m = m / 10
    k += 1
  }
  if k < 1 {
    1
  } else {
    k
  }
}

///|
priv struct VegasLimit {
  rule : Vegas
  roll : () -> Double
  mut estimate : Double
  mut noload : Int64
  mut count : Int32
  mut jitter : Double
}

///|
impl Adapt for VegasLimit with fn limit(self) {
  self.estimate.to_int()
}

///|
impl Adapt for VegasLimit with fn sample(self, s) {
  if s.rtt <= 0L {
    return
  }
  let r = self.rule
  self.count += 1
  if self.jitter * r.probe.to_double() * self.estimate <= self.count.to_double() {
    self.jitter = 0.5 + 0.5 * (self.roll)()
    self.count = 0
    self.noload = s.rtt
    return
  }
  if self.noload == 0L || s.rtt < self.noload {
    self.noload = s.rtt
    return
  }
  let est = self.estimate
  let log = log10(est.to_int())
  let queued = (est * (1.0 - self.noload.to_double() / s.rtt.to_double()))
    .ceil()
    .to_int()
  let next = if s.dropped {
    est - (r.step * log).to_double()
  } else if (s.flying * 2).to_double() < est {
    return
  } else if queued <= r.threshold * log {
    est + (r.beta * log).to_double()
  } else if queued < r.alpha * log {
    est + (r.step * log).to_double()
  } else if queued > r.beta * log {
    est - (r.step * log).to_double()
  } else {
    return
  }
  let next = next.clamp(min=1.0, max=r.max.to_double())
  self.estimate = (1.0 - r.smoothing) * est + r.smoothing * next
}

///|
priv struct GradientLimit {
  rule : Gradient
  mut estimate : Double
  mut long : Double
  mut sum : Double
  mut count : Int32
}

///|
impl Adapt for GradientLimit with fn limit(self) {
  self.estimate.to_int()
}

///|
/// Fold a response time into the long-run average: a plain mean over the first
/// ten, then an exponential average over `window`.
fn GradientLimit::average(self : GradientLimit, rtt : Double) -> Double {
  if self.count < 10 {
    self.count += 1
    self.sum += rtt
    self.long = self.sum / self.count.to_double()
  } else {
    let factor = 2.0 / (self.rule.window.to_double() + 1.0)
    self.long = self.long * (1.0 - factor) + rtt * factor
  }
  self.long
}

///|
impl Adapt for GradientLimit with fn sample(self, s) {
  let r = self.rule
  let short = s.rtt.to_double()
  let long = self.average(short)
  // After a long overload the average lags far behind; pulling it down here
  // brings the limit back without waiting out the window.
  if long / short > 2.0 {
    self.long = self.long * 0.95
  }
  let est = self.estimate
  if s.flying.to_double() < est / 2.0 {
    return
  }
  let slope = (r.tolerance * long / short).clamp(min=0.5, max=1.0)
  let next = est * slope + r.queue.to_double()
  let next = est * (1.0 - r.smoothing) + next * r.smoothing
  self.estimate = next.clamp(min=r.min.to_double(), max=r.max.to_double())
}

///|
/// A concurrency limit that adapts to the response times of the calls it lets
/// through.
///
/// Ask with [`Limiter::acquire`] before each call. `None` means the limit is
/// reached and the call should be refused or queued; `Some` is a lease to settle
/// once the call is done, which is where the rule learns.
pub struct Limiter {
  adapt : &Adapt
  mut flying : Int32
}

///|
/// A limiter on one of the rules that ship.
///
/// # Parameters
/// - `rule` : how the limit moves; `Vegas(vegas)` by default, as in Netflix concurrency-limits
/// - `roll` : a draw from 0 to 1, used only by Vegas to spread its no-queue measurements so a fleet does not take them in step; a constant `0.5` by default
pub fn Limiter::new(
  rule~ : Rule = Vegas(vegas),
  roll~ : () -> Double = () => 0.5,
) -> Limiter {
  let adapt : &Adapt = match rule {
    Fixed(n) => (Still::{ limit: n, } : &Adapt)
    Aimd(r) => (AimdLimit::{ rule: r, limit: r.initial, } : &Adapt)
    Vegas(r) =>
      (
        VegasLimit::{
          rule: r,
          roll,
          estimate: r.initial.to_double(),
          noload: 0L,
          count: 0,
          jitter: 0.5 + 0.5 * roll(),
        } : &Adapt)
    Gradient(r) =>
      (
        GradientLimit::{
          rule: r,
          estimate: r.initial.to_double(),
          long: 0.0,
          sum: 0.0,
          count: 0,
        } : &Adapt)
  }
  { adapt, flying: 0, }
}

///|
/// A limiter on a rule of your own.
pub fn Limiter::custom(adapt : &Adapt) -> Limiter {
  { adapt, flying: 0, }
}

///|
/// The most calls that may be in flight now.
pub fn Limiter::limit(self : Limiter) -> Int32 {
  self.adapt.limit()
}

///|
/// How many calls are in flight.
pub fn Limiter::flying(self : Limiter) -> Int32 {
  self.flying
}

///|
/// Ask to start one call at `now`, in nanoseconds from the caller's clock.
pub fn Limiter::acquire(self : Limiter, now : Int64) -> Lease? {
  if self.flying >= self.adapt.limit() {
    return None
  }
  self.flying += 1
  Some({ limiter: self, start: now, flying: self.flying, })
}

///|
/// A call the limiter let through. Exactly one of `pass`, `fail` and `ignore`
/// settles it.
pub struct Lease {
  limiter : Limiter
  start : Int64
  flying : Int32
}

///|
/// The call finished at `now`, and its response time is a sample.
pub fn Lease::pass(self : Lease, now : Int64) -> Unit {
  self.settle(now, false)
}

///|
/// The call timed out or was refused further down at `now`: the rule backs off.
pub fn Lease::fail(self : Lease, now : Int64) -> Unit {
  self.settle(now, true)
}

///|
/// The call ended in a way that says nothing about load, such as a bad request.
/// It leaves flight and is not a sample.
pub fn Lease::ignore(self : Lease) -> Unit {
  self.limiter.flying -= 1
}

///|
fn Lease::settle(self : Lease, now : Int64, dropped : Bool) -> Unit {
  let l = self.limiter
  l.flying -= 1
  l.adapt.sample({ rtt: now - self.start, flying: self.flying, dropped, })
}
