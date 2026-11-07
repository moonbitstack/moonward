// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
fn feed(l : Limiter, rtt : Int64, flying : Int32, dropped? : Bool) -> Int32 {
  l.adapt.sample({ rtt, flying, dropped: dropped.unwrap_or(false), })
  l.limit()
}

///|
test "aimd starts at its initial limit, under the floor or not" {
  assert_eq(Limiter::new(rule=Aimd({ ..aimd, initial: 10, })).limit(), 10)
}

///|
test "aimd grows by one while the limit is half used" {
  let l = Limiter::new(rule=Aimd(aimd))
  assert_eq(feed(l, ms(1L), 10), 21)
}

///|
test "aimd holds still while the caller uses less than half" {
  let l = Limiter::new(rule=Aimd(aimd))
  assert_eq(feed(l, ms(1L), 9), 20)
}

///|
test "aimd keeps 90% on a drop" {
  let l = Limiter::new(rule=Aimd({ ..aimd, initial: 30, }))
  assert_eq(feed(l, 0L, 0, dropped=true), 27)
}

///|
test "aimd counts a call over the timeout as a drop" {
  let l = Limiter::new(rule=Aimd({ ..aimd, initial: 30, }))
  assert_eq(feed(l, ms(5001L), 30), 27)
  let patient = Limiter::new(
    rule=Aimd(Aimd::new(initial=30, timeout=@moondate.Span::new(seconds=10L))),
  )
  assert_eq(feed(patient, ms(5001L), 30), 31)
}

///|
test "aimd stays at the ceiling" {
  let l = Limiter::new(rule=Aimd({ ..aimd, initial: 21, max: 21, min: 0, }))
  assert_eq(feed(l, ms(1L), 10), 21)
}

///|
test "aimd backoff is a knob" {
  let l = Limiter::new(
    rule=Aimd({ ..aimd, initial: 100, min: 0, backoff: 0.5, }),
  )
  assert_eq(feed(l, 0L, 0, dropped=true), 50)
}

///|
/// The rule Netflix's own Vegas tests run against.
fn small_vegas() -> Limiter {
  Limiter::new(
    rule=Vegas({
      ..vegas,
      alpha: 3,
      beta: 6,
      smoothing: 1.0,
      initial: 10,
      max: 20,
    }),
  )
}

///|
test "vegas grows by beta when nothing is queued" {
  let l = small_vegas()
  assert_eq(feed(l, ms(10L), 10), 10)
  assert_eq(feed(l, ms(10L), 11), 16)
}

///|
test "vegas grows by beta with one call queued, the threshold itself" {
  let l = small_vegas()
  assert_eq(feed(l, ms(10L), 10), 10)
  // 10 * (1 - 10 / 11) rounds up to one queued call
  assert_eq(feed(l, ms(11L), 11), 16)
}

///|
test "vegas shrinks a step when the queue is long" {
  let l = small_vegas()
  assert_eq(feed(l, ms(10L), 10), 10)
  assert_eq(feed(l, ms(50L), 11), 9)
}

///|
test "vegas holds still between alpha and beta" {
  let l = small_vegas()
  assert_eq(feed(l, ms(10L), 10), 10)
  assert_eq(feed(l, ms(14L), 14), 10)
}

///|
test "vegas scales its thresholds with the logarithm of the limit" {
  let l = Limiter::new(rule=Vegas({ ..vegas, initial: 10000, max: 20000, }))
  assert_eq(feed(l, ms(10_000L), 5000), 10000)
  assert_eq(feed(l, ms(10_000L), 6000), 10024)
}

///|
test "vegas smoothing moves part of the way" {
  let l = Limiter::new(
    rule=Vegas({ ..vegas, smoothing: 0.5, initial: 100, max: 200, }),
  )
  assert_eq(feed(l, ms(10L), 100), 100)
  // queued 50 is over beta 12: 100 - 2 = 98, half way is 99
  assert_eq(feed(l, ms(20L), 100), 99)
  // queued 50 is over beta 6 at 99: 99 - 1 = 98, half way is 98.5
  assert_eq(feed(l, ms(20L), 100), 98)
}

///|
test "vegas steps down on a drop" {
  let l = small_vegas()
  assert_eq(feed(l, ms(10L), 10), 10)
  assert_eq(feed(l, ms(10L), 11, dropped=true), 9)
}

///|
test "vegas measures the no-queue time again when the probe comes round" {
  let probing = Limiter::new(
    rule=Vegas({ ..vegas, alpha: 3, beta: 6, initial: 10, max: 20, probe: 1, }),
    roll=() => 0.0,
  )
  let steady = Limiter::new(
    rule=Vegas({ ..vegas, alpha: 3, beta: 6, initial: 10, max: 20, probe: 100, }),
    roll=() => 0.0,
  )
  for l in [probing, steady] {
    ignore(feed(l, ms(10L), 10))
    for _ in 0..<3 {
      ignore(feed(l, ms(10L), 0))
    }
    ignore(feed(l, ms(50L), 0))
  }
  // the fifth call was the probe: 50 ms is now the time with no queue
  assert_eq(feed(probing, ms(50L), 11), 16)
  assert_eq(feed(steady, ms(50L), 11), 9)
}

///|
test "vegas ignores a call that took no time" {
  let l = small_vegas()
  assert_eq(feed(l, 0L, 11, dropped=true), 10)
}

///|
test "gradient holds still while the caller uses less than half" {
  let l = Limiter::new(rule=Gradient(gradient))
  assert_eq(feed(l, ms(10L), 9), 20)
}

///|
test "gradient grows by its queue while response times hold" {
  let l = Limiter::new(rule=Gradient(gradient))
  // 20 * 0.8 + (20 + 4) * 0.2 = 20.8
  assert_eq(feed(l, ms(10L), 20), 20)
  // 20.8 * 0.8 + (20.8 + 4) * 0.2 = 21.6
  assert_eq(feed(l, ms(10L), 20), 21)
}

///|
test "gradient shrinks when calls get slower than usual" {
  let l = Limiter::new(
    rule=Gradient({ ..gradient, initial: 100, min: 1, smoothing: 1.0, }),
  )
  for _ in 0..<10 {
    ignore(feed(l, ms(10L), 100))
  }
  let before = l.limit()
  // four times slower than the average: the slope bottoms out at a half
  assert_eq(feed(l, ms(40L), 100), before / 2 + 4)
}

///|
test "gradient floor and tolerance are knobs" {
  let floored = Limiter::new(
    rule=Gradient({ ..gradient, initial: 100, smoothing: 1.0, }),
  )
  let tolerant = Limiter::new(
    rule=Gradient({ ..gradient, initial: 100, smoothing: 1.0, tolerance: 10.0, }),
  )
  for l in [floored, tolerant] {
    for _ in 0..<10 {
      ignore(feed(l, ms(10L), 100))
    }
  }
  let before = tolerant.limit()
  // a tolerance of 10 takes a call four times slower in its stride
  assert_eq(feed(tolerant, ms(40L), 100), before + 4)
  for _ in 0..<50 {
    ignore(feed(floored, ms(1000L), 1000))
  }
  assert_eq(floored.limit(), 20)
}

///|
test "gradient pulls a lagging average down" {
  let g : GradientLimit = {
    rule: gradient,
    estimate: 20.0,
    long: 0.0,
    sum: 0.0,
    count: 0,
  }
  for _ in 0..<10 {
    Adapt::sample(g, { rtt: ms(100L), flying: 0, dropped: false, })
  }
  assert_eq(g.long, ms(100L).to_double())
  Adapt::sample(g, { rtt: ms(10L), flying: 0, dropped: false, })
  let factor = 2.0 / 601.0
  let averaged = ms(100L).to_double() * (1.0 - factor) +
    ms(10L).to_double() * factor
  assert_eq(g.long, averaged * 0.95)
}

///|
test "the limiter refuses at the limit and admits again once a call settles" {
  let l = Limiter::new(rule=Fixed(2))
  guard l.acquire(0L) is Some(a) else { fail("refused under the limit") }
  guard l.acquire(0L) is Some(_) else { fail("refused under the limit") }
  assert_eq(l.acquire(0L) is None, true)
  assert_eq(l.flying(), 2)
  a.pass(ms(1L))
  assert_eq(l.flying(), 1)
  assert_eq(l.acquire(ms(1L)) is Some(_), true)
}

///|
priv struct Recorder {
  seen : Array[Sample]
}

///|
impl Adapt for Recorder with fn limit(_) {
  3
}

///|
impl Adapt for Recorder with fn sample(self, s) {
  self.seen.push(s)
}

///|
test "a rule of your own sees each settled call, and an ignored one not at all" {
  let r : Recorder = { seen: [], }
  let l = Limiter::custom(r)
  guard l.acquire(ms(1L)) is Some(a) else { fail("refused") }
  guard l.acquire(ms(2L)) is Some(b) else { fail("refused") }
  guard l.acquire(ms(3L)) is Some(c) else { fail("refused") }
  a.pass(ms(11L))
  b.fail(ms(32L))
  c.ignore()
  assert_eq(l.flying(), 0)
  assert_eq(r.seen, [
    { rtt: ms(10L), flying: 1, dropped: false, },
    { rtt: ms(30L), flying: 2, dropped: true, },
  ])
}

///|
test "the three ways to write a rule agree" {
  assert_eq(Aimd::new(max=500), { ..aimd, max: 500, })
  assert_eq(Vegas::new(smoothing=0.5), { ..vegas, smoothing: 0.5, })
  assert_eq(Gradient::new(queue=8), { ..gradient, queue: 8, })
  assert_eq(Aimd::new(), aimd)
  assert_eq(Vegas::new(), vegas)
  assert_eq(Gradient::new(), gradient)
}

///|
test "the default limiter is vegas from twenty" {
  assert_eq(Limiter::new().limit(), 20)
}

///|
test "log10 rounds down and never goes under one" {
  assert_eq([0, 1, 9, 10, 99, 100, 10000].map(log10), [1, 1, 1, 1, 1, 2, 4])
}
