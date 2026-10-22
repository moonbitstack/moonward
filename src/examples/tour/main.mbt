// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
fn ms(n : Int64) -> Int64 {
  n * 1_000_000L
}

///|
/// A fixed spread of draws in `[0, 1)`, so the run prints the same every time.
fn roll(i : Int64) -> Double {
  (i * 7919L % 1000L).to_double() / 1000.0
}

///|
/// A backend that fails every call between two and six seconds in. One call
/// every 20 ms goes through the breaker; each half second prints how much it
/// refused and the ratio it stands at.
fn breaker() -> Unit {
  let b = @moonward.Breaker::new()
  let mut sent = 0
  let mut refused = 0
  for i in 0L..<500L {
    let now = ms(i * 20L)
    match b.allow(now, roll(i)) {
      Some(p) => {
        sent += 1
        if now >= ms(2000L) && now < ms(6000L) {
          p.fail(now)
        } else {
          p.pass(now)
        }
      }
      None => refused += 1
    }
    if (i + 1L) % 25L == 0L {
      let ratio = (b.ratio(now) * 100.0).round().to_int()
      println(
        "\{(i + 1L) * 20L} ms  sent \{sent}  refused \{refused}  ratio \{ratio}%",
      )
      sent = 0
      refused = 0
    }
  }
}

///|
/// A server whose calls take 50 ms, sent a call every millisecond while the CPU
/// is at 95%: once more calls are in flight than it has shown it can finish,
/// the shedder starts refusing.
fn shedder() -> Unit {
  let s = @moonward.Shedder::new()
  let open : Array[(@moonward.Ticket, Int64)] = []
  let mut refused = 0
  for i in 0L..<3000L {
    let now = ms(i)
    while open.length() > 0 && open[0].1 <= now {
      let (t, _) = open.remove(0)
      t.pass(now)
    }
    match s.allow(now, if i < 1000L { 200 } else { 950 }) {
      Some(t) => open.push((t, now + ms(50L)))
      None => refused += 1
    }
  }
  println("in flight \{s.flying()}  refused \{refused} of 3000")
}

///|
fn main {
  breaker()
  println("")
  shedder()
  println("")
  let day = @moondate.Span::new(days=1L)
  let bucket = @moonward.Bucket::new(2.0, burst=3.0)
  let burst = [0, 1, 2, 3].map(_ => bucket.take(0L))
  println(
    "bucket   \{@debug.to_string(burst)}, next in \{bucket.next(0L).total_seconds()} s",
  )
  let quota = @moonward.Period::new(2, day, align=true)
  println("period   \{@debug.to_string([0, 1, 2].map(_ => quota.take(0L)))}")
  let gate = @moonward.Gate::new(1)
  println("gate     \{gate.enter()} \{gate.enter()}")
  let delays = @moonward.backoff.schedule(randoms=[0.5, 0.5])
  println("backoff  \{@debug.to_string(delays.map(d => d.total_seconds()))} s")
  let d = @moonward.Deadline::start(@moondate.Span::new(seconds=2L), 0L)
  println("deadline \{d.expired(ms(1500L))} \{d.expired(ms(2000L))}")
}
