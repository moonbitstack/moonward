// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The constants of adaptive load shedding.
///
/// The preset is [`shed`]. Build another with [`Shed::new`], or update one in
/// place with `{ ..shed, cpu: 800 }`.
pub(all) struct Shed {
  /// Buckets in the window the throughput and response times are read from.
  size : Int32
  /// How far back that window reaches.
  window : @moondate.Span
  /// CPU use in thousandths at and above which the server counts as overloaded.
  cpu : Int32
  /// The response time assumed while the window has none, long enough that a
  /// server with no history is not shed.
  latency : @moondate.Span
  /// Weight of the old value in the moving average of calls in flight. Updated
  /// only as calls finish, so it lags a surge and admits a little more of it.
  beta : Double
  /// How long the server stays hot after the CPU falls back under the threshold,
  /// if it has been shedding.
  cool : @moondate.Span
  /// The least share of the estimated capacity admitted however high the CPU is.
  floor : Double
} derive(Eq, Debug)

///|
pub extend Shed with Debug::{to_repr}

///|
pub extend Shed with Eq::{not_equal, equal}

///|
/// The preset: five seconds in fifty buckets, overloaded at 90% CPU, a one-second
/// assumed response time, an average weighted 0.9, one second to cool and never
/// less than a tenth of capacity.
///
/// The memory is short on purpose: a five-second window follows the load it is
/// in rather than averaging a burst away, and the floor keeps a server already at
/// full CPU from being told it can serve nobody.
pub let shed : Shed = {
  size: 50,
  window: @moondate.Span::new(seconds=5L),
  cpu: 900,
  latency: @moondate.Span::new(seconds=1L),
  beta: 0.9,
  cool: @moondate.Span::new(seconds=1L),
  floor: 0.1,
}

///|
/// A policy by name, every knob with the preset's value.
///
/// # Parameters
/// - `size` : buckets in the window, `50` in the preset
/// - `window` : how far back that window reaches, `5 s` in the preset
/// - `cpu` : CPU use in thousandths at or above which the server counts as hot, `900` in the preset
/// - `latency` : response time assumed while the window has none, `1 s` in the preset
/// - `beta` : weight of the old value in the moving average of calls in flight, `0.9` in the preset
/// - `cool` : how long the server stays hot after the CPU falls back, `1 s` in the preset
/// - `floor` : the least share of capacity admitted however high the CPU is, `0.1` in the preset
pub fn Shed::new(
  size~ : Int32 = shed.size,
  window~ : @moondate.Span = shed.window,
  cpu~ : Int32 = shed.cpu,
  latency~ : @moondate.Span = shed.latency,
  beta~ : Double = shed.beta,
  cool~ : @moondate.Span = shed.cool,
  floor~ : Double = shed.floor,
) -> Shed {
  { size, window, cpu, latency, beta, cool, floor, }
}

///|
/// Load shedding that refuses work only when the server is both hot and full.
///
/// Hot means the CPU is at or over the threshold, or was within the cooling time
/// and the shedder has refused since. Full means more calls are in flight than the
/// server has shown it can finish: the busiest bucket's passes per millisecond
/// times the fastest bucket's mean response time, scaled down as the CPU nears
/// 100%. Both the moving average and the current count of calls in flight must be
/// over that figure.
///
/// A CPU spike with nothing queued sheds nothing, and neither does a queue on an
/// idle CPU. CPU use is read by the caller, in thousandths, and passed to each
/// [`Shedder::allow`].
pub struct Shedder {
  shed : Shed
  passes : Window[Total]
  latencies : Window[Total]
  mut flying : Int64
  mut average : Double
  mut hot : Int64?
  mut dropped : Bool
}

///|
/// A shedder with empty windows opening at `now`.
///
/// # Parameters
/// - `shed` : the policy; the [`shed`](#shed) preset by default
/// - `now` : the clock reading both windows open at, `0L` by default
pub fn Shedder::new(shed~ : Shed = shed, now~ : Int64 = 0L) -> Shedder {
  {
    shed,
    passes: Window::new(size=shed.size, window=shed.window, now~),
    latencies: Window::new(size=shed.size, window=shed.window, now~),
    flying: 0L,
    average: 0.0,
    hot: None,
    dropped: false,
  }
}

///|
/// How many calls are in flight.
pub fn Shedder::flying(self : Shedder) -> Int64 {
  self.flying
}

///|
/// The most calls the server has finished in one bucket, at least one.
fn Shedder::busiest(self : Shedder, now : Int64) -> Int64 {
  let mut most = 1L
  self.passes.each(now, b => if b.sum > most { most = b.sum }, current=false)
  most
}

///|
/// The lowest mean response time of any bucket, in milliseconds.
fn Shedder::fastest(self : Shedder, now : Int64) -> Double {
  let mut least = self.shed.latency.nanos.to_double() / 1.0e6
  self.latencies.each(
    now,
    b => {
      if b.count > 0L {
        let mean = (b.sum.to_double() / b.count.to_double()).round()
        if mean < least {
          least = mean
        }
      }
    },
    current=false,
  )
  least
}

///|
/// How many calls in flight the server can carry at `cpu`.
fn Shedder::capacity(self : Shedder, now : Int64, cpu : Int32) -> Double {
  let per_ms = 1.0e6 / self.passes.width().nanos.to_double()
  let flight = self.busiest(now).to_double() * self.fastest(now) * per_ms
  let factor = (1000.0 - cpu.to_double()) / (1000.0 - self.shed.cpu.to_double())
  let factor = if factor < self.shed.floor {
    self.shed.floor
  } else if factor > 1.0 {
    1.0
  } else {
    factor
  }
  (if flight < 1.0 { 1.0 } else { flight }) * factor
}

///|
/// Whether the server counts as hot at `now`.
fn Shedder::heated(self : Shedder, now : Int64, cpu : Int32) -> Bool {
  if cpu >= self.shed.cpu {
    self.hot = Some(now)
    return true
  }
  if !self.dropped {
    return false
  }
  match self.hot {
    Some(t) if now - t < self.shed.cool.nanos => true
    _ => {
      self.dropped = false
      false
    }
  }
}

///|
/// Ask to start one call at `now`, with the CPU at `cpu` thousandths.
///
/// `Some` means go ahead, and the caller settles the ticket once the call has
/// finished.
///
/// # Parameters
/// - `now` : the caller's clock reading, in nanoseconds
/// - `cpu` : CPU use in thousandths, read by the caller
pub fn Shedder::allow(self : Shedder, now : Int64, cpu : Int32) -> Ticket? {
  if self.heated(now, cpu) {
    let cap = self.capacity(now, cpu)
    if self.average > cap && self.flying.to_double() > cap {
      self.dropped = true
      return None
    }
  }
  self.flying += 1L
  Some({ shedder: self, start: now, })
}

///|
/// One fewer call in flight, folded into the moving average.
fn Shedder::land(self : Shedder) -> Unit {
  self.flying -= 1L
  let beta = self.shed.beta
  self.average = self.average * beta + self.flying.to_double() * (1.0 - beta)
}

///|
/// A call the shedder let through. Exactly one of `pass` and `fail` settles it.
pub struct Ticket {
  shedder : Shedder
  start : Int64
}

///|
/// The call succeeded at `now`. Its response time counts towards what the server
/// has shown it can do.
///
/// # Parameters
/// - `now` : the clock reading the call finished at; its response time counts towards capacity
pub fn Ticket::pass(self : Ticket, now : Int64) -> Unit {
  let s = self.shedder
  s.land()
  let ms = ((now - self.start).to_double() / 1.0e6).ceil().to_int64()
  s.latencies.slot(now).add(ms)
  s.passes.slot(now).add(1L)
}

///|
/// The call failed. It leaves flight but says nothing about capacity.
pub fn Ticket::fail(self : Ticket) -> Unit {
  self.shedder.land()
}
