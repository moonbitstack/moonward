///|
/// The first gradient rule answers what Netflix concurrency-limits' `GradientLimit`
/// answered, sample by sample.
test "MinRtt follows the reference limit after every sample" {
  for v in min_rtt_vectors() {
    let limiter = Limiter::new(rule=MinRtt(v.rule))
    for i, rtt in v.rtts {
      limiter.adapt.sample({ rtt, flying: v.flying[i], dropped: v.dropped[i], })
      let got = limiter.adapt.limit()
      if got != v.limits[i] {
        fail("\{v.name}, sample \{i}: limit \{got}, reference \{v.limits[i]}")
      }
    }
  }
}

///|
test "MinRtt probes on schedule: the limit falls to the queue and the fastest time is forgotten" {
  let rule = MinRtt::new(initial=100, probe=4)
  let limiter = Limiter::new(rule=MinRtt(rule), roll=() => 0.0)
  // A probe is due after four samples, the countdown being `probe` with no jitter.
  for _ in 0..<4 {
    limiter.adapt.sample({ rtt: 10_000_000L, flying: 100, dropped: false, })
  }
  assert_true(limiter.adapt.limit() > 10)
  limiter.adapt.sample({ rtt: 10_000_000L, flying: 100, dropped: false, })
  // The limit had grown 100, 110, 120, 130, 141; the probe drops it to the square
  // root of 141, at least four.
  assert_eq(limiter.adapt.limit(), 11)
}

///|
test "MinRtt with probe 0 never probes" {
  let limiter = Limiter::new(rule=MinRtt({ ..min_rtt, probe: 0, }))
  for _ in 0..<5000 {
    limiter.adapt.sample({ rtt: 10_000_000L, flying: 1000, dropped: false, })
  }
  assert_eq(limiter.adapt.limit(), 1000)
}

///|
test "the default rule is still Vegas" {
  assert_true(
    Limiter::new().adapt.limit() ==
    Limiter::new(rule=Vegas(vegas)).adapt.limit(),
  )
}

///|
test "MinRtt written three ways is the same rule" {
  assert_eq(MinRtt::new(probe=0, queue=Fixed(8)), {
    ..min_rtt,
    probe: 0,
    queue: Fixed(8),
  })
  assert_eq(MinRtt::new(), min_rtt)
}

///|
/// A store with one slot and a version that only a compare-and-set moves, shared
/// by every process that counts against the quota.
priv struct Store {
  mut slot : Usage?
  mut version : Int32
}

///|
/// Count one event through the store, reading again whenever another process wrote
/// in between, as a caller of `Period::step` does.
fn Store::count(
  self : Store,
  period : Period,
  now : Int64,
  writes : Array[() -> Unit],
) -> Quota {
  while true {
    let seen = self.version
    let state = self.slot.unwrap_or(period.opening())
    let counted = period.step(state, now)
    // Another process gets its turn between this one's read and its write.
    if writes.pop() is Some(other) {
      other()
    }
    if self.version == seen {
      self.slot = Some(counted.state)
      self.version += 1
      return counted.quota
    }
  }
  Under
}

///|
test "two processes on one stored period share the quota" {
  let store = Store::{ slot: None, version: 0, }
  let a = Period::new(3, @moondate.Span::new(seconds=10L))
  let b = Period::new(3, @moondate.Span::new(seconds=10L))
  assert_eq(store.count(a, 0L, []), Under)
  assert_eq(store.count(b, 1L, []), Under)
  assert_eq(store.count(a, 2L, []), Hit)
  assert_eq(store.count(b, 3L, []), Over)
  // A new period opens once ten seconds have passed since the first event.
  assert_eq(store.count(b, 10_000_000_000L, []), Under)
  assert_eq(store.slot.unwrap().used, 1)
}

///|
test "a write that lost the race counts again and does not spend the last event twice" {
  let store = Store::{ slot: None, version: 0, }
  let p = Period::new(2, @moondate.Span::new(seconds=10L))
  assert_eq(store.count(p, 0L, []), Under)
  // While the first process holds `used 1`, a second one counts and writes.
  let raced = store.count(p, 1L, [fn() { ignore(store.count(p, 1L, [])) }])
  // Both believed they took the last event; asked again, the slower one is over.
  assert_eq(raced, Over)
  assert_eq(store.slot.unwrap().used, 3)
}

///|
test "a period closes at its end, not a nanosecond later" {
  let p = Period::new(1, { nanos: 100L, })
  assert_eq(p.take(0L), Hit)
  assert_eq(p.take(99L), Over)
  assert_eq(p.take(100L), Hit)
}

///|
test "a chain gives back what it took when a later limiter refuses" {
  let bucket = Bucket::new(0.0, burst=1.0)
  let gate = Gate::new(1)
  ignore(gate.enter())
  let chain = Chained::new([bucket, gate])
  assert_false(chain.acquire(0L))
  // The token the bucket handed out was returned, so it is still there.
  assert_eq(bucket.tokens(0L), 1.0)
  gate.leave()
  assert_true(chain.acquire(0L))
  assert_eq(bucket.tokens(0L), 0.0)
  assert_eq(gate.held(), 1)
}

///|
test "a refused event is not counted against a period" {
  let p = Period::new(1, @moondate.Span::new(seconds=1L))
  assert_true(p.acquire(0L))
  assert_false(p.acquire(1L))
  assert_eq(p.left(1L), 0)
  p.release(2L)
  assert_eq(p.left(2L), 1)
}

///|
test "a sliding window takes back its latest stamp" {
  let w = Sliding::new(1, @moondate.Span::new(seconds=1L))
  assert_true(w.acquire(0L))
  w.release(0L)
  assert_true(w.acquire(5L))
}

///|
test "partitions keep the keys used last and start a dropped key afresh" {
  let made : Array[String] = []
  let parts = Partitioned::new(
    key => {
      made.push(key)
      Gate::new(1)
    },
    limit=2,
  )
  assert_true(parts.acquire("a", 0L))
  assert_true(parts.acquire("b", 0L))
  // "a" is used again, so "b" is the least recent when "c" arrives.
  assert_false(parts.acquire("a", 0L))
  assert_true(parts.acquire("c", 0L))
  assert_eq(parts.length(), 2)
  assert_false(parts.acquire("a", 0L))
  // "b" was dropped: its gate comes back empty.
  assert_true(parts.acquire("b", 0L))
  assert_eq(made, ["a", "b", "c", "b"])
}

///|
test "partitions hold at least one key" {
  let parts = Partitioned::new(_ => Gate::new(1), limit=0)
  ignore(parts.get("a"))
  ignore(parts.get("b"))
  assert_eq(parts.length(), 1)
}

///|
suberror NotFound

///|
test "a call through the breaker counts its outcome" {
  let b = Breaker::new()
  let clock = () => 0L
  assert_eq(b.call(clock, 0.5, () => 7), 7)
  let failed = try {
    b.call(clock, 0.5, () => raise NotFound)
    false
  } catch {
    NotFound => true
    _ => false
  }
  assert_true(failed)
  // A not found the caller accepts is the caller's business, not the service's.
  let accepted = try {
    b.call(clock, 0.5, () => raise NotFound, acceptable=e => e is NotFound)
    false
  } catch {
    NotFound => true
    _ => false
  }
  assert_true(accepted)
  let t = Tally::default()
  b.win.each(0L, current=true, bucket => {
    t.success += bucket.success
    t.failure += bucket.failure
  })
  assert_eq(t.success, 2L)
  assert_eq(t.failure, 1L)
}

///|
test "a refused call raises Unavailable or answers with the fallback" {
  let b = Breaker::new()
  let clock = () => 0L
  // Enough failures that every roll below the drop share is refused.
  for _ in 0..<200 {
    let _ : Int32 = b.call(clock, 0.99, () => raise NotFound) catch { _ => 0 }
  }
  let refused = try {
    ignore(b.call(clock, 0.0, () => 1))
    false
  } catch {
    Unavailable => true
    _ => false
  }
  assert_true(refused)
  assert_eq(b.call(clock, 0.0, () => 1, fallback=_ => 42), 42)
}
