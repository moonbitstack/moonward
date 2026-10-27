// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A rolling window: `size` buckets that together cover the last `window` of
/// time, oldest dropping off as time moves on.
///
/// The bucket type is the caller's. A breaker keeps a [`Tally`] of outcomes per
/// bucket, a shedder a [`Total`] of response times; anything with a `Default` can
/// be a bucket, and the default is what a bucket is cleared back to.
///
/// Time never moves on its own: every call carries the `now` it happens at.
/// Writing at a later `now` clears the buckets the gap swept past; reading at a
/// later `now` skips them without clearing, so a window nobody writes to still
/// ages out, and two reads at the same `now` agree.
pub struct Window[B] {
  width : Int64
  buckets : Array[B]
  mut head : Int32
  mut start : Int64
}

///|
/// An empty window of `size` buckets spanning `window`, its first bucket opening
/// at `now`.
///
/// A size below one is raised to one, and so is a bucket narrower than a
/// nanosecond.
///
/// # Parameters
/// - `size` : how many buckets; anything under one is raised to one
/// - `window` : how much time the buckets together cover
/// - `now` : the clock reading the first bucket opens at, `0L` by default
pub fn[B : Default] Window::new(
  size~ : Int32,
  window~ : @moondate.Span,
  now~ : Int64 = 0L,
) -> Window[B] {
  let size = if size < 1 { 1 } else { size }
  let width = window.nanos / size.to_int64()
  {
    width: if width < 1L {
      1L
    } else {
      width
    },
    buckets: Array::makei(size, _ => B::default()),
    head: 0,
    start: now,
  }
}

///|
/// How many buckets the window has.
pub fn[B] Window::size(self : Window[B]) -> Int32 {
  self.buckets.length()
}

///|
/// How much time one bucket covers.
pub fn[B] Window::width(self : Window[B]) -> @moondate.Span {
  { nanos: self.width, }
}

///|
/// How many buckets have elapsed since the head opened, at most `size` because
/// beyond that the whole window is stale. A clock that moves backwards counts as
/// no time at all.
fn[B] Window::span(self : Window[B], now : Int64) -> Int32 {
  let n = (now - self.start) / self.width
  let size = self.buckets.length()
  if n <= 0L {
    0
  } else if n < size.to_int64() {
    n.to_int()
  } else {
    size
  }
}

///|
/// The bucket `now` falls in, for the caller to add to.
///
/// The buckets the gap since the last write swept past are cleared first. The
/// head is snapped back to a bucket boundary, so buckets keep their width rather
/// than drifting with the arrival time of each write.
///
/// # Parameters
/// - `now` : the caller's clock reading, in nanoseconds
pub fn[B : Default] Window::slot(self : Window[B], now : Int64) -> B {
  let span = self.span(now)
  if span > 0 {
    let size = self.buckets.length()
    for i in 0..<span {
      self.buckets[(self.head + i + 1) % size] = B::default()
    }
    self.head = (self.head + span) % size
    self.start = now - (now - self.start) % self.width
  }
  self.buckets[self.head]
}

///|
/// Visit the buckets still inside the window at `now`, oldest first.
///
/// With `current` false the bucket `now` falls in is left out: it has seen only
/// part of its time, and a reading that takes the busiest or the fastest bucket
/// should not compare a partial one against whole ones.
///
/// # Parameters
/// - `now` : the caller's clock reading, in nanoseconds
/// - `f` : called once per live bucket, oldest first
/// - `current` : whether to include the bucket `now` falls in, `true` by default
pub fn[B] Window::each(
  self : Window[B],
  now : Int64,
  f : (B) -> Unit,
  current~ : Bool = true,
) -> Unit {
  let size = self.buckets.length()
  let span = self.span(now)
  let live = if span == 0 && !current { size - 1 } else { size - span }
  let first = (self.head + span + 1) % size
  for i in 0..<live {
    f(self.buckets[(first + i) % size])
  }
}

///|
/// How a call ended, as a breaker records it.
///
/// A `Drop` is a call refused before it ran: traffic, but neither a success nor a
/// failure of whatever is downstream.
pub(all) enum Outcome {
  Success
  Failure
  Drop
} derive(Eq, Debug)

///|
pub extend Outcome with Debug::{to_repr}

///|
pub extend Outcome with Eq::{not_equal, equal}

///|
/// Outcomes counted in one bucket.
///
/// `total` counts every call including the dropped ones, so a bucket being
/// throttled still reads as busy rather than idle.
pub struct Tally {
  mut total : Int64
  mut success : Int64
  mut failure : Int64
  mut drop : Int64
} derive(Default, Eq, Debug)

///|
pub extend Tally with Default::{default}

///|
pub extend Tally with Debug::{to_repr}

///|
pub extend Tally with Eq::{not_equal, equal}

///|
/// Count one call ending as `o`.
///
/// # Parameters
/// - `o` : how the call ended
pub fn Tally::add(self : Tally, o : Outcome) -> Unit {
  self.total += 1L
  match o {
    Success => self.success += 1L
    Failure => self.failure += 1L
    Drop => self.drop += 1L
  }
}

///|
/// A sum and how many values went into it, which is a mean once `count` is
/// positive.
pub struct Total {
  mut sum : Int64
  mut count : Int64
} derive(Default, Eq, Debug)

///|
pub extend Total with Default::{default}

///|
pub extend Total with Debug::{to_repr}

///|
pub extend Total with Eq::{not_equal, equal}

///|
/// Add one value.
///
/// # Parameters
/// - `v` : the value to fold into the sum
pub fn Total::add(self : Total, v : Int64) -> Unit {
  self.sum += v
  self.count += 1L
}
