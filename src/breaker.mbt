// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The constants of Google SRE's client-side throttling.
///
/// The preset is [`sre`]. Build another with [`Sre::new`], or update one in place
/// with `{ ..sre, k: 2.0 }`.
pub(all) struct Sre {
  /// How many calls each success pays for. At 1.5 a backend is left alone until
  /// more than a third of its calls fail.
  k : Double
  /// What `k` decays to while every bucket at the head of the window is failing,
  /// so past successes count for less the longer an outage lasts.
  floor : Double
  /// Calls every backend gets regardless, which keeps a quiet one from throttling
  /// itself over two bad calls.
  protection : Double
  /// After this long with nothing let through, one call is let through anyway, so
  /// a backend that has recovered is noticed.
  probe : @moondate.Span
  /// Buckets in the window.
  size : Int32
  /// How far back the window reaches.
  window : @moondate.Span
} derive(Eq, Debug)

///|
pub extend Sre with Debug::{to_repr}

///|
pub extend Sre with Eq::{not_equal, equal}

///|
/// The preset: `k` 1.5 decaying to 1.1, five calls of protection, a probe every
/// second, and ten seconds of history in forty buckets.
///
/// These are the constants of go-zero's `core/breaker/googlebreaker.go`. `k` and
/// `protection` are the `K` and the floor of the SRE book's equation 21-1; the
/// decay, the probe and the recovery scaling are go-zero's additions.
pub let sre : Sre = {
  k: 1.5,
  floor: 1.1,
  protection: 5.0,
  probe: @moondate.Span::new(seconds=1L),
  size: 40,
  window: @moondate.Span::new(seconds=10L),
}

///|
/// A policy by name, every knob with the preset's value.
pub fn Sre::new(
  k~ : Double = sre.k,
  floor~ : Double = sre.floor,
  protection~ : Double = sre.protection,
  probe~ : @moondate.Span = sre.probe,
  size~ : Int32 = sre.size,
  window~ : @moondate.Span = sre.window,
) -> Sre {
  { k, floor, protection, probe, size, window, }
}

///|
/// The window folded the way go-zero folds it. `failing` and `working` are runs
/// at the head of the window, not totals: a bucket that saw both a success and a
/// failure ends both runs, and an empty bucket ends neither.
priv struct Health {
  mut accepts : Int64
  mut total : Int64
  mut failing : Int64
  mut working : Int64
}

///|
/// A circuit breaker that sheds a fraction of calls rather than all of them.
///
/// There is no open, half-open and closed: the breaker keeps a rolling window of
/// outcomes and refuses each new call with a probability that grows with the
/// failures in it. A struggling backend keeps receiving as much as it can still
/// serve, instead of being cut off and then flooded again when it recovers.
///
/// With `accepts` successes out of `total` calls in the window, `failing` the run
/// of all-failure buckets at its head and `working` the run of all-success ones:
///
/// ```text
/// w     = max(k - (k - floor) × failing / size, floor)
/// drop  = (total - protection - w × accepts) / (total + 1)
/// drop ×= (size - working) / size
/// ```
///
/// A `drop` at or below zero lets everything through, which is the whole healthy
/// case.
pub struct Breaker {
  sre : Sre
  win : Window[Tally]
  mut last : Int64?
}

///|
/// A breaker with an empty window opening at `now`.
pub fn Breaker::new(sre~ : Sre = sre, now~ : Int64 = 0L) -> Breaker {
  { sre, win: Window::new(size=sre.size, window=sre.window, now~), last: None, }
}

///|
fn Breaker::health(self : Breaker, now : Int64) -> Health {
  let h = Health::{ accepts: 0L, total: 0L, failing: 0L, working: 0L, }
  self.win.each(now, b => {
    h.accepts += b.success
    h.total += b.total
    if b.failure > 0L {
      h.working = 0L
    } else if b.success > 0L {
      h.working += 1L
    }
    if b.success > 0L {
      h.failing = 0L
    } else if b.failure > 0L {
      h.failing += 1L
    }
  })
  h
}

///|
/// The unscaled drop fraction, and the factor that eases it off as clean buckets
/// pile up.
fn Breaker::odds(self : Breaker, now : Int64) -> (Double, Double) {
  let h = self.health(now)
  let size = self.win.size().to_double()
  let { k, floor, protection, .. } = self.sre
  let w = k - (k - floor) * h.failing.to_double() / size
  let weighted = (if w > floor { w } else { floor }) * h.accepts.to_double()
  let drop = (h.total.to_double() - protection - weighted) /
    (h.total + 1L).to_double()
  (drop, (size - h.working.to_double()) / size)
}

///|
/// The fraction of calls the breaker would refuse at `now`, zero while the window
/// is healthy.
///
/// The probe is left out: this is the standing throttle, which is what a dashboard
/// or an alert wants.
pub fn Breaker::ratio(self : Breaker, now : Int64) -> Double {
  let (drop, ease) = self.odds(now)
  if drop <= 0.0 {
    0.0
  } else {
    drop * ease
  }
}

///|
/// Ask to make one call at `now`.
///
/// `roll` is a draw from `[0, 1)`; the call is refused when it falls under the
/// drop fraction. `Some` means go ahead, and the caller settles the promise once
/// the call has finished. A refusal is recorded as a `Drop`, so a breaker that is
/// refusing never reads back as idle and throttles itself off.
pub fn Breaker::allow(self : Breaker, now : Int64, roll : Double) -> Promise? {
  let (drop, ease) = self.odds(now)
  if drop <= 0.0 {
    return Some({ breaker: self, })
  }
  if self.last is Some(t) && now - t > self.sre.probe.nanos {
    self.last = Some(now)
    return Some({ breaker: self, })
  }
  if roll < drop * ease {
    self.win.slot(now).add(Drop)
    None
  } else {
    self.last = Some(now)
    Some({ breaker: self, })
  }
}

///|
/// A call the breaker let through. Exactly one of `pass` and `fail` settles it;
/// until then the window holds no record of how the call went.
pub struct Promise {
  breaker : Breaker
}

///|
/// The call succeeded.
pub fn Promise::pass(self : Promise, now : Int64) -> Unit {
  self.breaker.win.slot(now).add(Success)
}

///|
/// The call failed.
pub fn Promise::fail(self : Promise, now : Int64) -> Unit {
  self.breaker.win.slot(now).add(Failure)
}
