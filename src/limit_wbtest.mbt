// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "a bucket starts full, which is what lets the first burst through" {
  let b = Bucket::new(1.0, burst=5.0)
  for i = 0; i < 5; i = i + 1 {
    assert_eq(b.take(0L), true)
  }
  // The sixth has nothing left and no time has passed.
  assert_eq(b.take(0L), false)
}

///|
test "tokens accrue at the rate, up to the burst and no further" {
  let b = Bucket::new(2.0, burst=4.0)
  for i = 0; i < 4; i = i + 1 {
    assert_eq(b.take(0L), true)
  }
  // Half a second at two a second is one token.
  assert_eq(b.take(sec(1L) / 2L), true)
  assert_eq(b.take(sec(1L) / 2L), false)
  // An hour of quiet does not bank an hour of requests: the burst is the ceiling.
  assert_eq(b.tokens(sec(3600L)), 4.0)
}

///|
test "a bucket says how long until it would let one through" {
  let b = Bucket::new(2.0, burst=2.0)
  assert_eq(b.next(0L).nanos, 0L)
  assert_eq(b.take(0L), true)
  assert_eq(b.take(0L), true)
  // Empty, and two a second means half a second for the next.
  assert_eq(b.next(0L).nanos, sec(1L) / 2L)
  // Asking for four at two a second is two seconds.
  assert_eq(b.next(0L, n=4.0).nanos, sec(2L))
  // And once the time has passed it is zero again.
  assert_eq(b.next(sec(1L)).nanos, 0L)
}

///|
test "a burst smaller than one would refuse everything, so it is raised" {
  let b = Bucket::new(0.5)
  assert_eq(b.take(0L), true)
  let named = Bucket::new(0.5, burst=0.0)
  assert_eq(named.take(0L), true)
}

///|
test "a window counts events rather than smoothing them" {
  let w = Sliding::new(3, @moondate.Span::new(seconds=10L))
  assert_eq(w.take(0L), true)
  assert_eq(w.take(0L), true)
  assert_eq(w.take(0L), true)
  assert_eq(w.take(0L), false)
  assert_eq(w.left(0L), 0)
  // The three fall out together ten seconds after they went in.
  assert_eq(w.take(sec(9L)), false)
  assert_eq(w.take(sec(10L)), true)
  assert_eq(w.left(sec(10L)), 2)
}

///|
test "a window slides rather than resetting on a boundary" {
  let w = Sliding::new(2, @moondate.Span::new(seconds=10L))
  assert_eq(w.take(0L), true)
  assert_eq(w.take(sec(5L)), true)
  assert_eq(w.take(sec(6L)), false)
  // The first falls out at ten seconds, not at some fixed boundary, so there is
  // room for one and only one.
  assert_eq(w.take(sec(10L)), true)
  assert_eq(w.take(sec(11L)), false)
  // And the second falls out at fifteen.
  assert_eq(w.take(sec(15L)), true)
}

///|
test "a window says when it will next have room" {
  let w = Sliding::new(2, @moondate.Span::new(seconds=10L))
  assert_eq(w.next(0L).nanos, 0L)
  assert_eq(w.take(0L), true)
  assert_eq(w.take(sec(2L)), true)
  // Full, and the oldest went in at zero, so ten seconds from then.
  assert_eq(w.next(sec(3L)).nanos, sec(7L))
  assert_eq(w.next(sec(10L)).nanos, 0L)
}

///|
test "a gate counts what is happening at once, with no clock at all" {
  let g = Gate::new(2)
  assert_eq(g.enter(), true)
  assert_eq(g.enter(), true)
  assert_eq(g.enter(), false)
  assert_eq(g.held(), 2)
  g.leave()
  assert_eq(g.enter(), true)
  // Leaving more often than entering does not go negative.
  g.leave()
  g.leave()
  g.leave()
  assert_eq(g.held(), 0)
}

///|
test "a gate with no limit lets everything through" {
  let g = Gate::new(0)
  for i = 0; i < 1000; i = i + 1 {
    assert_eq(g.enter(), true)
  }
  assert_eq(g.held(), 1000)
}

///|
test "a clock that goes backwards does not create tokens" {
  let b = Bucket::new(1.0, burst=2.0, now=sec(100L))
  assert_eq(b.take(sec(100L)), true)
  assert_eq(b.take(sec(100L)), true)
  // A reading earlier than the last one accrues nothing rather than a negative
  // amount, which a subtraction alone would give.
  assert_eq(b.take(sec(50L)), false)
  assert_eq(b.tokens(sec(50L)), 0.0)
}

///|
test "a period admits the quota, flags the last one and refuses the rest" {
  let p = Period::new(3, @moondate.Span::new(seconds=10L))
  assert_eq(p.take(sec(1L)), Under)
  assert_eq(p.take(sec(2L)), Under)
  assert_eq(p.take(sec(3L)), Hit)
  assert_eq(p.take(sec(4L)), Over)
  assert_eq(p.left(sec(4L)), 0)
  // the period opened at the first event, so it closes ten seconds after it
  assert_eq(p.next(sec(4L)), @moondate.Span::new(seconds=7L))
  assert_eq(p.take(sec(11L)), Under)
  assert_eq(p.left(sec(11L)), 2)
}

///|
test "an aligned period opens on a multiple of its length" {
  let p = Period::new(2, @moondate.Span::new(seconds=10L), align=true)
  assert_eq(p.take(sec(17L)), Under)
  assert_eq(p.next(sec(17L)), @moondate.Span::new(seconds=3L))
  assert_eq(p.take(sec(19L)), Hit)
  // twenty is the next multiple, so the count starts again there
  assert_eq(p.take(sec(20L)), Under)
  let q = Period::new(2, @moondate.Span::new(seconds=10L))
  assert_eq(q.take(sec(17L)), Under)
  assert_eq(q.take(sec(20L)), Hit)
}

///|
test "a period gives nothing back to a clock that moves backwards" {
  let p = Period::new(1, @moondate.Span::new(seconds=10L))
  assert_eq(p.take(sec(100L)), Hit)
  assert_eq(p.take(sec(50L)), Over)
}

///|
test "asking about a period does not open one" {
  let p = Period::new(2, @moondate.Span::new(seconds=10L))
  assert_eq(p.left(sec(1L)), 2)
  assert_eq(p.next(sec(1L)), @moondate.Span::new())
  assert_eq(p.take(sec(5L)), Under)
  assert_eq(p.next(sec(5L)), @moondate.Span::new(seconds=10L))
}

///|
test "asking about a bucket spends nothing" {
  let b = Bucket::new(1.0, burst=1.0)
  let before = b.state
  // The two readings fetch a copy of the state rather than moving the bucket on.
  assert_eq(b.next(0L).nanos, 0L)
  assert_eq(b.tokens(sec(1L)), 1.0)
  assert_eq(b.state, before)
  // And the state they were read from answers the next call the same way taking
  // it would.
  assert_eq(b.step(before, 0L).granted, true)
  assert_eq(b.take(0L), true)
}

///|
test "a store with no key starts where a new bucket starts" {
  let b = Bucket::new(4.0, now=sec(3L))
  assert_eq(b.opening(sec(3L)), b.state)
  // Wherever the store is asked, an opening bucket is full.
  assert_eq(b.opening(sec(9L)).tokens, 4.0)
}

///|
test "a write that lost a race is asked again rather than counted twice" {
  let bucket = Bucket::new(1.0, burst=2.0)
  // One slot and a version, which only a compare-and-set moves.
  let slot : Array[Tokens?] = [None]
  let version : Array[Int32] = [0]
  // Two processes read the same state, two tokens, and both ask.
  let seen = version[0]
  let first = bucket.step(bucket.opening(0L), 0L)
  let second = bucket.step(bucket.opening(0L), 0L)
  assert_eq(first.granted, true)
  assert_eq(second.granted, true)
  // The first writes back, so the second's version no longer matches.
  slot[0] = Some(first.state)
  version[0] = 1
  assert_eq(version[0] == seen, false)
  // Asked again against what the store holds, the second takes the one token
  // that is left rather than a copy of the one already spent.
  let again = bucket.step(slot[0].unwrap(), 0L)
  assert_eq(again.granted, true)
  assert_eq(again.state.tokens, 0.0)
  slot[0] = Some(again.state)
  assert_eq(bucket.step(slot[0].unwrap(), 0L).granted, false)
}

///|
test "a cost below zero takes nothing and hands nothing out" {
  let b = Bucket::new(1.0, burst=1.0)
  assert_eq(b.take(0L), true)
  assert_eq(b.tokens(0L), 0.0)
  // A subtraction alone would credit the bucket four tokens here.
  assert_eq(b.take(0L, n=-4.0), true)
  assert_eq(b.tokens(0L), 0.0)
}

///|
test "a window with no quota admits nothing and never says when" {
  let w = Sliding::new(0, @moondate.Span::new(seconds=1L))
  assert_eq(w.take(0L), false)
  assert_eq(w.left(0L), 0)
  // A year rather than a zero a caller would spin on.
  assert_eq(w.next(0L), @moondate.Span::new(days=365L))
}

///|
/// Two numbers within a rounding of the arithmetic that produced them.
fn near(a : Double, b : Double) -> Bool {
  let d = a - b
  (if d < 0.0 { -d } else { d }) <= 1.0e-9
}

///|
/// Replay one set of vectors: every decision must match exactly, and every token
/// count to within a rounding, since the reference got there by another path.
fn replay_buckets(cases : Array[BucketVector]) -> Unit raise {
  for c in cases {
    let b = Bucket::new(c.rate, burst=c.burst)
    for i = 0; i < c.times.length(); i = i + 1 {
      let granted = b.take(c.times[i], n=c.costs[i])
      if granted != c.granted[i] {
        fail(
          "a bucket of " +
          c.rate.to_string() +
          " per second and " +
          c.burst.to_string() +
          " burst, call " +
          i.to_string() +
          ": granted " +
          granted.to_string() +
          ", the reference granted " +
          c.granted[i].to_string(),
        )
      }
      let left = b.tokens(c.times[i])
      if !near(left, c.tokens[i]) {
        fail(
          "a bucket of " +
          c.rate.to_string() +
          " per second and " +
          c.burst.to_string() +
          " burst, call " +
          i.to_string() +
          ": left " +
          left.to_string() +
          ", the reference left " +
          c.tokens[i].to_string(),
        )
      }
    }
  }
}

///|
test "a bucket refilled between calls answers as the reference does" {
  replay_buckets(bucket_vectors_continuous())
}

///|
test "a bucket refilled a tick at a time answers as the reference does" {
  replay_buckets(bucket_vectors_ticked())
}
