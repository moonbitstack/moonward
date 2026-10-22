// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A span as whole milliseconds, which is the unit every retry policy is written in.
fn milli(s : @moondate.Span) -> Int64 {
  s.nanos / 1_000_000L
}

///|
test "the ceiling doubles from the base and stops at the cap" {
  let b = Backoff::new(attempts=8)
  assert_eq(milli(b.ceiling(1)), 100L)
  assert_eq(milli(b.ceiling(2)), 200L)
  assert_eq(milli(b.ceiling(3)), 400L)
  assert_eq(milli(b.ceiling(4)), 800L)
  // The cap is one second, so it stops there rather than reaching 1600.
  assert_eq(milli(b.ceiling(5)), 1000L)
  assert_eq(milli(b.ceiling(50)), 1000L)
  // A retry index below one is not a retry.
  assert_eq(milli(b.ceiling(0)), 0L)
}

///|
test "the preset is the one gRPC documents" {
  assert_eq(backoff.attempts, 3)
  assert_eq(milli(backoff.base), 100L)
  assert_eq(milli(backoff.cap), 1000L)
  assert_eq(backoff.factor, 2.0)
  assert_eq(backoff.jitter, Full)
}

///|
test "attempts bound the retries, the first attempt being one" {
  let b = Backoff::new(attempts=3)
  assert_eq(b.more(0), true)
  assert_eq(b.more(1), true)
  assert_eq(b.more(2), true)
  // Three attempts made is three attempts, so no more.
  assert_eq(b.more(3), false)
  assert_eq(b.more(4), false)
  // One attempt means no retry at all.
  assert_eq(Backoff::new(attempts=1).more(1), false)
}

///|
test "each jitter draws where its definition says" {
  let rigid = Backoff::new(jitter=Rigid)
  let full = Backoff::new(jitter=Full)
  let equal = Backoff::new(jitter=Equal)
  // Rigid ignores the draw entirely.
  assert_eq(milli(rigid.delay(2, random=0.0)), 200L)
  assert_eq(milli(rigid.delay(2, random=0.9)), 200L)
  // Full spans the whole ceiling.
  assert_eq(milli(full.delay(2, random=0.0)), 0L)
  assert_eq(milli(full.delay(2, random=0.5)), 100L)
  // Equal keeps a floor of half and spans the other half.
  assert_eq(milli(equal.delay(2, random=0.0)), 100L)
  assert_eq(milli(equal.delay(2, random=0.5)), 150L)
}

///|
test "decorrelated grows from where it last landed, not from the attempt number" {
  let b = Backoff::new(
    jitter=Decorrelated,
    cap=@moondate.Span::new(seconds=10L),
  )
  // With no previous delay it draws in [base, base × 3]. The draw is half-open, so
  // the top is approached and never reached.
  assert_eq(milli(b.delay(1, random=0.0)), 100L)
  assert_eq(milli(b.delay(1, random=0.5)), 200L)
  let first = b.delay(1, random=0.999999999)
  assert_eq(milli(first) < 300L && milli(first) >= 299L, true)
  // The next draws in [base, previous × 3], so a long wait begets a longer one.
  let prior = @moondate.Span::new(millis=300L)
  assert_eq(milli(b.delay(2, random=0.0, previous=prior)), 100L)
  assert_eq(milli(b.delay(2, random=0.5, previous=prior)), 500L)
  // And it is held under the cap like every other strategy.
  let huge = @moondate.Span::new(seconds=8L)
  assert_eq(
    milli(b.delay(9, random=0.999999999, previous=huge)) <= 10_000L,
    true,
  )
}

///|
test "a draw outside its range lands inside the policy rather than outside it" {
  let b = Backoff::new(jitter=Full)
  assert_eq(milli(b.delay(3, random=-1.0)), 0L)
  assert_eq(milli(b.delay(3, random=2.0)) <= 400L, true)
}

///|
test "the same draws give the same sequence, which is what makes it testable" {
  let b = Backoff::new(attempts=5, jitter=Full)
  let draws = [0.25, 0.5, 0.75, 0.1]
  let once = b.schedule(randoms=draws[:])
  let twice = b.schedule(randoms=draws[:])
  assert_eq(once, twice)
  // Four attempts after the first is four delays.
  assert_eq(once.length(), 4)
  // 100×0.25, 200×0.5, 400×0.75, 800×0.1 — the ceiling doubles, the draw scales it.
  assert_eq(once.map(milli), [25L, 100L, 300L, 80L])
  // Draws that run short fall back to the low end rather than to nothing.
  assert_eq(b.schedule().map(milli), [0L, 0L, 0L, 0L])
}

///|
test "a rigid schedule is the doubling sequence every policy writes out" {
  let b = Backoff::new(attempts=6, jitter=Rigid)
  assert_eq(b.schedule().map(milli), [100L, 200L, 400L, 800L, 1000L])
}

///|
test "the three ways of building a backoff agree" {
  let named = Backoff::new(attempts=5, jitter=Rigid)
  let updated = { ..backoff, attempts: 5, jitter: Rigid, }
  assert_eq(named, updated)
  assert_eq(named.schedule(), updated.schedule())
}
