// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The engine behind the interactive panels on the site.
///
/// Every frame the page draws is computed here by calling the published
/// primitives, so the page has no model of its own. Only integers cross the
/// border — thousandths of a probability, permille of a token count,
/// microseconds of a delay — so no float ever has to survive JSON.
///
/// The clock is still the caller's: `now` is a millisecond counter this package
/// advances itself, and `now * 1_000_000` is the nanosecond stamp a primitive
/// takes. The dice are here too, one small generator seeded by the page.
extern "js" fn js_register(
  f : (Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32) -> String,
) -> Unit = "moonward_register"

///|
/// Milliseconds to the nanoseconds every primitive counts in.
fn ns(ms : Int64) -> Int64 {
  ms * 1_000_000L
}

///|
/// A small deterministic generator, so one seed draws one run twice.
struct Dice {
  mut state : Int64
}

///|
fn Dice::new(seed : Int64) -> Dice {
  { state: (seed & 0x7FFF_FFFFL) + 1L, }
}

///|
/// A draw from `[0, 1)`: what a breaker's roll and a backoff's jitter take.
fn Dice::roll(self : Dice) -> Double {
  self.state = (self.state * 6364136223846793005L + 1442695040888963407L) &
    0x00FF_FFFF_FFFF_FFFFL
  (self.state % 1000003L).to_double() / 1000003.0
}

///|
/// True with probability `bp` in ten thousand.
fn Dice::chance(self : Dice, bp : Int32) -> Bool {
  self.roll() * 10000.0 < bp.to_double()
}

///|
/// An integer array as JSON.
fn ints(xs : Array[Int32]) -> String {
  let mut out = "["
  for i, v in xs {
    if i > 0 {
      out = out + ","
    }
    out = out + "\{v}"
  }
  out + "]"
}

///|
/// Arrays of arrays, for a panel that returns many runs at once.
fn rows(xs : Array[String]) -> String {
  let mut out = "["
  for i, v in xs {
    if i > 0 {
      out = out + ","
    }
    out = out + v
  }
  out + "]"
}

///|
/// The sum of an array, for the totals a panel prints beside its graph.
fn total(xs : Array[Int32]) -> Int32 {
  let mut sum = 0
  for v in xs {
    sum = sum + v
  }
  sum
}

///|
/// One breaker, one stream of requests, sampled every hundred milliseconds.
///
/// The knobs are the call interval, the stretch the backend is failing over, how
/// much of the traffic fails there in ten thousand, and the seed.
fn breaker(
  interval : Int32,
  fail_from : Int32,
  fail_to : Int32,
  duration : Int32,
  bp : Int32,
  seed : Int32,
) -> String {
  let b = @moonward.Breaker::new()
  let dice = Dice::new(seed.to_int64())
  let step = 100L
  let ticks = duration.to_int64() / step
  let ratio : Array[Int32] = []
  let passed : Array[Int32] = []
  let failed : Array[Int32] = []
  let dropped : Array[Int32] = []
  let mut at = 0L
  for t in 0L..<ticks {
    let end = (t + 1L) * step
    let mut p = 0
    let mut f = 0
    let mut d = 0
    while at < end {
      let now = ns(at)
      match b.allow(now, dice.roll()) {
        Some(promise) =>
          if now >= ns(fail_from.to_int64()) &&
            now < ns(fail_to.to_int64()) &&
            dice.chance(bp) {
            promise.fail(now)
            f = f + 1
          } else {
            promise.pass(now)
            p = p + 1
          }
        None => d = d + 1
      }
      at = at + interval.to_int64()
    }
    ratio.push((b.ratio(ns(end)) * 1000.0).round().to_int())
    passed.push(p)
    failed.push(f)
    dropped.push(d)
  }
  "{\"step\":100,\"ratio\":" +
  ints(ratio) +
  ",\"pass\":" +
  ints(passed) +
  ",\"fail\":" +
  ints(failed) +
  ",\"drop\":" +
  ints(dropped) +
  ",\"admitted\":" +
  (total(passed) + total(failed)).to_string() +
  ",\"refused\":" +
  total(dropped).to_string() +
  "}"
}

///|
/// The same traffic through a bucket, a sliding window and a period, so the
/// three answers can be compared side by side.
fn limiters(
  demand : Int32,
  quota : Int32,
  burst : Int32,
  window : Int32,
  duration : Int32,
  seed : Int32,
) -> String {
  let dice = Dice::new(seed.to_int64())
  let span : @moondate.Span = { nanos: ns(window.to_int64()), }
  let bucket = @moonward.Bucket::new(quota.to_double(), burst=burst.to_double())
  let sliding = @moonward.Sliding::new(quota, span)
  let period = @moonward.Period::new(quota, span, align=true)
  let step = 100L
  let ticks = duration.to_int64() / step
  let in_bucket : Array[Int32] = []
  let in_sliding : Array[Int32] = []
  let in_period : Array[Int32] = []
  let left : Array[Int32] = []
  let mut sent = 0
  for t in 0L..<ticks {
    let end = (t + 1L) * step
    let now = ns(end)
    // A demand of ninety a second is nine calls a tick, and the tenths are
    // carried into the next tick rather than dropped.
    let target = demand * (t + 1L).to_int() / 10
    let want = target - sent
    sent = target
    let mut a = 0
    let mut s = 0
    let mut p = 0
    for _ in 0..<want {
      let _ = dice.roll()
      if bucket.take(now) {
        a = a + 1
      }
      if sliding.take(now) {
        s = s + 1
      }
      match period.take(now) {
        @moonward.Under | @moonward.Hit => p = p + 1
        @moonward.Over => ()
      }
    }
    in_bucket.push(a)
    in_sliding.push(s)
    in_period.push(p)
    left.push(
      (bucket.tokens(now) * 1000.0 / burst.to_double()).round().to_int(),
    )
  }
  "{\"step\":100,\"bucket\":" +
  ints(in_bucket) +
  ",\"sliding\":" +
  ints(in_sliding) +
  ",\"period\":" +
  ints(in_period) +
  ",\"left\":" +
  ints(left) +
  ",\"quota\":" +
  quota.to_string() +
  ",\"demand\":" +
  demand.to_string() +
  "}"
}

///|
/// The delay each of twenty-four clients would wait before retry `n`, one draw
/// each: the same policy, differing only in the draw, which is what jitter is
/// for.
fn backoff(
  base : Int32,
  factor_x10 : Int32,
  cap : Int32,
  attempts : Int32,
  jitter : Int32,
  seed : Int32,
) -> String {
  let kind = match jitter {
    0 => @moonward.Rigid
    1 => @moonward.Full
    2 => @moonward.Equal
    3 => @moonward.Decorrelated
    _ => @moonward.Spread(0.2)
  }
  let policy = @moonward.Backoff::new(
    base={ nanos: ns(base.to_int64()), },
    factor=factor_x10.to_double() / 10.0,
    cap={ nanos: ns(cap.to_int64()), },
    attempts~,
    jitter=kind,
  )
  let dice = Dice::new(seed.to_int64())
  let ceilings : Array[Int32] = []
  let runs : Array[String] = []
  for retry in 1..<attempts {
    ceilings.push((policy.ceiling(retry).nanos / 1000L).to_int())
    let us : Array[Int32] = []
    let mut last : @moondate.Span = { nanos: 0L, }
    for _ in 0..<24 {
      let d = policy.delay(retry, random=dice.roll(), previous=last)
      us.push((d.nanos / 1000L).to_int())
      last = d
    }
    runs.push(ints(us))
  }
  "{\"ceiling\":" + ints(ceilings) + ",\"runs\":" + rows(runs) + "}"
}

///|
/// A server whose load climbs over the run: calls in flight, what the shedder
/// took, and what it refused once the server was both hot and full.
fn shedder(
  demand : Int32,
  service : Int32,
  duration : Int32,
  seed : Int32,
) -> String {
  let s = @moonward.Shedder::new()
  let dice = Dice::new(seed.to_int64())
  let step = 10L
  let ticks = duration.to_int64() / step
  let open : Array[(@moonward.Ticket, Int64)] = []
  let flying : Array[Int32] = []
  let taken : Array[Int32] = []
  let refused : Array[Int32] = []
  let cpus : Array[Int32] = []
  let mut carry = 0
  for t in 0L..<ticks {
    let now = ns(t * step)
    let mut i = 0
    while i < open.length() {
      if open[i].1 <= t * step {
        let (ticket, _) = open.remove(i)
        ticket.pass(now)
      } else {
        i = i + 1
      }
    }
    // Load climbs over the run, and the CPU climbs with it.
    let load = demand * (30 + (t * 100L / ticks).to_int()) / 130
    carry = carry + load
    let mut want = 0
    while carry >= 100 {
      want = want + 1
      carry = carry - 100
    }
    let cpu = if load * service / 25 > 790 {
      990
    } else {
      200 + load * service / 25
    }
    let mut ok = 0
    let mut no = 0
    for _ in 0..<want {
      let roll = dice.roll()
      match s.allow(now, cpu) {
        Some(ticket) => {
          ok = ok + 1
          let take = service.to_int64() +
            (roll * service.to_double() / 3.0).to_int64()
          open.push((ticket, t * step + take))
        }
        None => no = no + 1
      }
    }
    if (t + 1L) % 10L == 0L {
      flying.push(s.flying().to_int())
      taken.push(ok)
      refused.push(no)
      cpus.push(cpu)
    }
  }
  "{\"step\":100,\"flying\":" +
  ints(flying) +
  ",\"taken\":" +
  ints(taken) +
  ",\"refused\":" +
  ints(refused) +
  ",\"cpu\":" +
  ints(cpus) +
  ",\"refused_total\":" +
  total(refused).to_string() +
  "}"
}

///|
/// One request from the page. `kind` picks the panel and the numbers after it are
/// that panel's knobs, in the order the page sends them.
fn run(
  kind : Int32,
  a : Int32,
  b : Int32,
  c : Int32,
  d : Int32,
  e : Int32,
  f : Int32,
  _ : Int32,
) -> String {
  match kind {
    0 => breaker(a, b, c, d, e, f)
    1 => limiters(a, b, c, d, e, f)
    2 => backoff(a, b, c, d, e, f)
    3 => shedder(a, b, c, d)
    _ => "{}"
  }
}

///|
fn main {
  js_register(run)
}
