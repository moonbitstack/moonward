// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The whole guide, in order, as one program. Every block in the guide is a
/// stretch of this file and the output printed under it is what this file
/// prints.
///
/// `moon run src/examples/guide`

///|
fn ms(n : Int64) -> Int64 {
  n * 1_000_000L
}

///|
/// A bucket type of our own, to show that a window takes any type with a
/// `Default`: here, how many requests a hundred milliseconds saw.
struct Hits {
  mut calls : Int64
} derive(Default, Debug)

///|
fn main {
  station_2()
  station_3()
  station_4()
  station_5()
  station_6()
  station_7()
  station_8()
  station_9()
  station_10()
}

///|
/// The first call: ask, then settle the promise.
fn station_2() -> Unit {
  let now = 0L
  let breaker = @moonward.Breaker::new()
  match breaker.allow(now, 0.42) {
    Some(call) => call.pass(now)
    None => println("backend refused")
  }
  println("--- 02  first call")
  println("empty window, ratio \{percent(breaker.ratio(now))}")
}

///|
/// What the breaker does as outcomes land. A success pays for one and a half
/// calls, so a window has to be about a third failures before it starts
/// refusing, and past that the refusal fraction climbs with every bad call.
fn station_3() -> Unit {
  let breaker = @moonward.Breaker::new()
  let mut at = 0L
  for _ in 0..<10 {
    at = tick(breaker, at, true)
  }
  println("--- 03  reading the breaker")
  println("10 good   ratio \{percent(breaker.ratio(at))}")
  for _ in 0..<15 {
    at = tick(breaker, at, false)
  }
  println("15 bad    ratio \{percent(breaker.ratio(at))}")
  for _ in 0..<15 {
    at = tick(breaker, at, false)
  }
  println("15 more   ratio \{percent(breaker.ratio(at))}")
}

///|
/// One call, a hundred milliseconds after the last: ask, then settle it.
fn tick(breaker : @moonward.Breaker, at : Int64, good : Bool) -> Int64 {
  let now = at + ms(100L)
  // A draw from [0, 1). Held at 0.5 here, so the refusal fraction and the draw
  // can be compared by eye.
  match breaker.allow(now, 0.5) {
    Some(call) => if good { call.pass(now) } else { call.fail(now) }
    None => ()
  }
  now
}

///|
/// A bucket: three tokens to spend, then a wait.
fn station_4() -> Unit {
  let bucket = @moonward.Bucket::new(2.0, burst=3.0)
  let took = [0, 1, 2, 3].map(_ => bucket.take(0L))
  println("--- 04  a bucket")
  println("took      \{@debug.to_string(took)}")
  println("tokens    \{bucket.tokens(0L)}")
  println("next      \{bucket.next(0L).nanos / 1_000_000L} ms")
}

///|
/// A quota counted two ways over the same three calls.
fn station_5() -> Unit {
  let second = @moondate.Span::new(seconds=1L)
  let sliding = @moonward.Sliding::new(2, second)
  let period = @moonward.Period::new(2, second, align=true)
  println("--- 05  quotas")
  println(
    "sliding   \{@debug.to_string([0L, 1L, 2L].map(_ => sliding.take(0L)))}",
  )
  println(
    "period    \{@debug.to_string([0L, 1L, 2L].map(_ => period.take(0L)))}",
  )
  println("left      \{sliding.left(0L)} of 2")
}

///|
/// Room right now, which has nothing to do with time.
fn station_6() -> Unit {
  let gate = @moonward.Gate::new(2)
  println("--- 06  room")
  println("enter     \{gate.enter()} \{gate.enter()} \{gate.enter()}")
  println("held      \{gate.held()}")
  gate.leave()
  println("after one leaves, held \{gate.held()}, enter \{gate.enter()}")
}

///|
/// A server that is hot and full. Calls take 50 ms and never finish early, so
/// the queue is what makes the shedder pull the lever.
fn station_7() -> Unit {
  let shedder = @moonward.Shedder::new()
  let open : Array[(@moonward.Ticket, Int64)] = []
  let mut refused = 0
  for i in 0L..<2000L {
    let now = ms(i)
    let mut k = 0
    while k < open.length() {
      if open[k].1 <= i {
        let (ticket, _) = open.remove(k)
        ticket.pass(now)
      } else {
        k = k + 1
      }
    }
    // Idle at first, then the CPU pins at 95%.
    let cpu = if i < 500L { 200 } else { 950 }
    match shedder.allow(now, cpu) {
      Some(ticket) => open.push((ticket, i + 50L))
      None => refused = refused + 1
    }
  }
  println("--- 07  load")
  println("in flight \{shedder.flying()}  refused \{refused} of 2000")
}

///|
/// Three jitter strategies over the same policy.
fn station_8() -> Unit {
  let rigid = @moonward.Backoff::new(jitter=Rigid)
  let full = @moonward.Backoff::new(jitter=Full)
  let spread = @moonward.backoff
  println("--- 08  waiting")
  println(
    "ceiling   \{@debug.to_string([1, 2, 3].map(r => (spread.ceiling(r).nanos / 1_000_000L).to_int()))} ms",
  )
  println(
    "rigid     \{@debug.to_string(rigid.schedule(randoms=[0.9, 0.9]).map(d => (d.nanos / 1_000_000L).to_int()))} ms",
  )
  println(
    "full      \{@debug.to_string(full.schedule(randoms=[0.9, 0.9]).map(d => (d.nanos / 1_000_000L).to_int()))} ms",
  )
  println(
    "spread    \{@debug.to_string(spread.schedule(randoms=[0.9, 0.1]).map(d => (d.nanos / 1_000_000L).to_int()))} ms",
  )
  println("more      \{spread.more(2)} \{spread.more(3)}")
}

///|
/// A budget from an instant, and what is left of it.
fn station_9() -> Unit {
  let deadline = @moonward.Deadline::start(@moondate.Span::new(seconds=2L), 0L)
  println("--- 09  a budget")
  println("at 1.5 s  expired \{deadline.expired(ms(1500L))}")
  println("at 2.0 s  expired \{deadline.expired(ms(2000L))}")
  match deadline.remaining(ms(1500L)) {
    Some(left) => println("left      \{left.nanos / 1_000_000L} ms")
    None => println("left      none")
  }
}

///|
/// A window of our own bucket type: four buckets over four hundred
/// milliseconds, filled by hand.
fn station_10() -> Unit {
  let window : @moonward.Window[Hits] = @moonward.Window::new(
    size=4,
    window=@moondate.Span::new(millis=400L),
  )
  window.slot(0L).calls += 3
  window.slot(ms(100L)).calls += 5
  window.slot(ms(150L)).calls += 2
  let mut seen = 0L
  window.each(ms(150L), b => seen = seen + b.calls)
  println("--- 10  a window of your own")
  println(
    "width     \{window.width().nanos / 1_000_000L} ms, \{window.size()} buckets",
  )
  println("calls     \{seen} inside the window")
}

///|
/// A ratio as whole percent, which is what a reader wants on a line of output.
fn percent(v : Double) -> String {
  "\{(v * 100.0).round().to_int()}%"
}
