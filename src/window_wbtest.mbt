// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Every bucket still in the window at `now`, added up.
fn sums(w : Window[Tally], now : Int64, current~ : Bool = true) -> Tally {
  let s = Tally::default()
  w.each(now, current~, b => {
    s.total += b.total
    s.success += b.success
    s.failure += b.failure
    s.drop += b.drop
  })
  s
}

///|
fn window(size : Int32, width : Int64, now~ : Int64 = 0L) -> Window[Tally] {
  Window::new(size~, window={ nanos: width * size.to_int64(), }, now~)
}

///|
test "a window holds size times width of history and nothing older" {
  let w = window(4, ms(100L))
  w.slot(ms(0L)).add(Success)
  w.slot(ms(100L)).add(Failure)
  w.slot(ms(200L)).add(Success)
  w.slot(ms(300L)).add(Success)
  assert_eq(sums(w, ms(300L)), {
    total: 4L,
    success: 3L,
    failure: 1L,
    drop: 0L,
  })
  // a write four buckets on clears the whole window before recording
  w.slot(ms(700L)).add(Drop)
  assert_eq(sums(w, ms(700L)), {
    total: 1L,
    success: 0L,
    failure: 0L,
    drop: 1L,
  })
}

///|
test "an idle window ages out on its own, and reading never clears it" {
  let w = window(4, ms(100L))
  w.slot(0L).add(Success)
  assert_eq(sums(w, ms(300L)).total, 1L)
  assert_eq(sums(w, ms(400L)).total, 0L)
  assert_eq(sums(w, ms(300L)).total, 1L)
}

///|
test "the head snaps to bucket boundaries instead of drifting" {
  let w = window(4, ms(100L))
  w.slot(0L).add(Success)
  assert_eq((w.head, w.start), (0, 0L))
  w.slot(ms(150L)).add(Failure)
  assert_eq((w.head, w.start), (1, ms(100L)))
  // 199 is still inside the same bucket
  w.slot(ms(199L)).add(Failure)
  assert_eq(w.head, 1)
  w.slot(ms(201L)).add(Success)
  assert_eq((w.head, w.start), (2, ms(200L)))
  assert_eq(sums(w, ms(201L)).success, 2L)
  assert_eq(sums(w, ms(201L)).failure, 2L)
}

///|
test "a read can leave out the bucket that is still filling" {
  let w = window(4, ms(100L))
  w.slot(0L).add(Success)
  w.slot(ms(100L)).add(Failure)
  assert_eq(sums(w, ms(150L), current=false).total, 1L)
  assert_eq(sums(w, ms(150L)).total, 2L)
  // once the clock is past the head, the head is whole and counts either way
  assert_eq(sums(w, ms(250L), current=false).total, 2L)
}

///|
test "a nonsense size is clamped and a backwards clock is no elapsed time" {
  let w : Window[Tally] = Window::new(size=0, window={ nanos: 0L, }, now=1000L)
  assert_eq(w.size(), 1)
  assert_eq(w.width(), { nanos: 1L, })
  w.slot(900L).add(Success)
  assert_eq(w.start, 1000L)
  assert_eq(sums(w, 900L).success, 1L)
}

///|
/// A bucket this package does not define, to show any `Default` type is one.
priv struct Peak {
  mut top : Int64
} derive(Default)

///|
test "a bucket can be any type with a default" {
  let w : Window[Peak] = Window::new(size=2, window={ nanos: ms(200L), })
  for v in [3L, 9L, 4L] {
    let b = w.slot(0L)
    if v > b.top {
      b.top = v
    }
  }
  w.slot(ms(100L)).top = 5L
  let tops = []
  w.each(ms(100L), b => tops.push(b.top))
  assert_eq(tops, [9L, 5L])
  assert_eq(w.width(), { nanos: ms(100L), })
}

///|
test "a total adds values and counts them" {
  let t = Total::default()
  t.add(4L)
  t.add(6L)
  assert_eq(t, { sum: 10L, count: 2L, })
}
