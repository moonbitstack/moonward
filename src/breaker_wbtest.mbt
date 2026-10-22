// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Take one call through the breaker at `now` and settle it as `o`. A roll of 1.0
/// never loses, so what a test sees is the formula with the draw taken out.
fn settle(b : Breaker, o : Outcome, now : Int64) -> Unit raise {
  guard b.allow(now, 1.0) is Some(p) else {
    fail("the breaker refused a call it should let through")
  }
  match o {
    Success => p.pass(now)
    Failure => p.fail(now)
    Drop => fail("a settled call is not a drop")
  }
}

///|
test "the drop ratio follows the SRE formula as failures pile up" {
  let b = Breaker::new()
  for _ in 0..<5 {
    settle(b, Failure, 0L)
  }
  // five failures are exactly the protection, so nothing is refused yet
  assert_eq(b.ratio(0L), 0.0)
  settle(b, Failure, 0L)
  assert_eq(b.ratio(0L), 1.0 / 7.0)
  settle(b, Failure, 0L)
  assert_eq(b.ratio(0L), 2.0 / 8.0)
  // one success is worth k = 1.5 against the seven failures
  settle(b, Success, 0L)
  assert_eq(b.ratio(0L), (8.0 - 5.0 - 1.5) / 9.0)
}

///|
test "a run of all-failure buckets decays the weight on past successes" {
  let b = Breaker::new()
  for _ in 0..<4 {
    settle(b, Success, 0L)
  }
  for _ in 0..<20 {
    settle(b, Failure, ms(250L))
  }
  // one failing bucket out of forty: w = 1.5 - 0.4 / 40 = 1.49, so the four
  // successes are worth 5.96 against 24 calls
  assert_eq(b.ratio(ms(250L)), 0.5216)
  for _ in 0..<20 {
    settle(b, Failure, ms(500L))
  }
  assert_eq(b.ratio(ms(500L)), 0.735111111111111)
}

///|
test "a healthy stream is never refused, however the roll lands" {
  let b = Breaker::new()
  for i in 0L..<200L {
    guard b.allow(ms(i * 50L), 0.0) is Some(p) else {
      fail("a healthy breaker refused a call")
    }
    p.pass(ms(i * 50L))
  }
  assert_eq(b.ratio(sec(10L)), 0.0)
}

///|
test "a refusal counts as traffic, and a silent second lets one probe through" {
  let b = Breaker::new()
  for _ in 0..<7 {
    settle(b, Failure, 0L)
  }
  assert_eq(b.ratio(0L), 0.25)
  // a roll of zero loses to any positive ratio
  assert_eq(b.allow(ms(100L), 0.0) is None, true)
  // the refusal is itself in the window: seven calls became eight
  assert_eq(b.ratio(ms(100L)), 3.0 / 9.0)
  // nothing has got through for over a second, so one call goes past the roll
  guard b.allow(ms(1101L), 0.0) is Some(p) else {
    fail("the probe was refused")
  }
  p.pass(ms(1101L))
  assert_eq(b.allow(ms(1101L), 0.0) is None, true)
}

///|
test "the window and the constants come from the policy" {
  let b = Breaker::new(sre={ ..sre, protection: 0.0, size: 4, })
  settle(b, Failure, 0L)
  assert_eq(b.ratio(0L), 0.5)
  assert_eq(b.win.width(), @moondate.Span::new(millis=2500L))
  // four buckets of 2.5 seconds forget the failure after ten
  assert_eq(b.ratio(sec(10L)), 0.0)
}

///|
test "three ways to write a policy agree" {
  let named = Sre::new(k=2.0, probe=@moondate.Span::new(seconds=3L))
  let updated = { ..sre, k: 2.0, probe: @moondate.Span::new(seconds=3L), }
  assert_eq(named, updated)
  assert_eq(Sre::new(), sre)
}
