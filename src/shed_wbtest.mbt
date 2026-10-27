// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The shape the model is easiest to check in: ten buckets of 100 ms, so a pass per bucket is 0.01 per
/// millisecond, its `windowFactor`.
fn shedder() -> Shedder {
  Shedder::new(shed={
    ..shed,
    size: 10,
    window: @moondate.Span::new(seconds=1L),
  })
}

///|
/// Bucket `i` gets `(i + 1) × 100` passes and the response times `10i + 1` to
/// `10i + 10` milliseconds, which is the history these tests build. Returns
/// the instant the last bucket was written at.
fn history(s : Shedder) -> Int64 {
  for i in 0L..<10L {
    let now = ms(i * 100L)
    s.passes.slot(now).add((i + 1L) * 100L)
    for j in (i * 10L + 1L)..<=(i * 10L + 10L) {
      s.latencies.slot(now).add(j)
    }
  }
  ms(900L)
}

///|
test "the busiest bucket is the most passes, at least one" {
  let s = shedder()
  for i in 0L..<10L {
    s.passes.slot(ms(i * 100L)).add((i + 1L) * 100L)
  }
  // read a bucket later, so the last write is whole and counts
  assert_eq(s.busiest(ms(1000L)), 1000L)
  // read inside it, and the bucket still filling is left out
  assert_eq(s.busiest(ms(900L)), 900L)
  assert_eq(shedder().busiest(0L), 1L)
}

///|
test "the fastest bucket is the lowest rounded mean response time" {
  let s = shedder()
  let now = history(s)
  // the first bucket's mean is 5.5, rounded to 6
  assert_eq(s.fastest(now), 6.0)
  assert_eq(shedder().fastest(0L), 1000.0)
}

///|
test "capacity is passes per millisecond times the fastest response time" {
  let s = shedder()
  let now = history(s)
  // 900 passes × 6 ms × 0.01
  assert_eq(s.capacity(now, 0), 54.0)
  // at the threshold the factor is still one; halfway past it, a half
  assert_eq(s.capacity(now, 900), 54.0)
  assert_eq(s.capacity(now, 950), 27.0)
  // past that it never falls under a tenth
  assert_eq(s.capacity(now, 1000), 5.4)
  assert_eq(shedder().capacity(0L, 0), 10.0)
}

///|
test "a call is refused only when the server is hot and full" {
  let s = shedder()
  let now = history(s)
  // hot, but the average in flight is under 54
  s.average = 50.0
  assert_eq(s.allow(now, 900) is Some(_), true)
  s.flying = 0L
  // hot, the average is over, but the count in flight is not
  s.average = 80.0
  s.flying = 49L
  assert_eq(s.allow(now, 900) is Some(_), true)
  // hot and full
  s.average = 80.0
  s.flying = 80L
  assert_eq(s.allow(now, 900) is None, true)
  assert_eq(s.dropped, true)
  // full but cool: the CPU fell, and the cooling time is over
  assert_eq(s.allow(now + sec(1L), 0) is Some(_), true)
  assert_eq(s.dropped, false)
}

///|
test "a server that has been refusing stays hot for the cooling time" {
  let s = shedder()
  let now = history(s)
  // as the history ages the busiest and fastest buckets that remain give a
  // capacity of up to 960, so the load here is over it for the whole second
  s.average = 1000.0
  s.flying = 1000L
  assert_eq(s.allow(now, 900) is None, true)
  // the CPU is back under the threshold, but only half a second has passed
  assert_eq(s.allow(now + ms(500L), 0) is None, true)
  assert_eq(s.allow(now + ms(999L), 0) is None, true)
  assert_eq(s.allow(now + ms(1000L), 0) is Some(_), true)
}

///|
test "being hot means nothing without having refused" {
  let s = shedder()
  let now = history(s)
  s.average = 80.0
  s.flying = 80L
  // the CPU was over the threshold once, but nothing was refused then
  s.hot = Some(now)
  assert_eq(s.allow(now + ms(10L), 0) is Some(_), true)
  s.dropped = true
  s.hot = Some(now - sec(2L))
  assert_eq(s.heated(now, 0), false)
  s.dropped = true
  s.hot = Some(now)
  assert_eq(s.heated(now, 0), true)
}

///|
test "settling a ticket records the response time and moves the average" {
  let s = shedder()
  guard s.allow(0L, 0) is Some(a) else { fail("refused on an idle server") }
  guard s.allow(0L, 0) is Some(b) else { fail("refused on an idle server") }
  assert_eq(s.flying(), 2L)
  // 2.4 ms rounds up to 3
  a.pass(2_400_000L)
  assert_eq(s.flying(), 1L)
  assert_eq(s.average, 1.0 * (1.0 - 0.9))
  b.fail()
  assert_eq(s.flying(), 0L)
  assert_eq(s.average, 1.0 * (1.0 - 0.9) * 0.9)
  let lat = []
  s.latencies.each(0L, t => if t.count > 0L { lat.push(t.sum) })
  assert_eq(lat, [3L])
  let passes = []
  s.passes.each(0L, t => if t.count > 0L { passes.push(t.sum) })
  assert_eq(passes, [1L])
}

///|
test "a CPU spike with nothing queued refuses nothing" {
  let s = Shedder::new()
  for i in 0L..<1000L {
    let now = ms(i)
    guard s.allow(now, 1000) is Some(t) else {
      fail("refused with one call in flight")
    }
    t.pass(now + ms(1L))
  }
}

///|
test "three ways to write a policy agree" {
  let named = Shed::new(cpu=800, cool=@moondate.Span::new(seconds=2L))
  let updated = { ..shed, cpu: 800, cool: @moondate.Span::new(seconds=2L), }
  assert_eq(named, updated)
  assert_eq(Shed::new(), shed)
}
