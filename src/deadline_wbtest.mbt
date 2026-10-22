// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "a deadline counts down from where it started" {
  let d = Deadline::start(@moondate.Span::new(seconds=2L), sec(10L))
  assert_eq(d.expired(sec(11L)), false)
  assert_eq(d.remaining(sec(11L)), Some(@moondate.Span::new(seconds=1L)))
  assert_eq(d.expired(sec(12L)), true)
  assert_eq(d.remaining(sec(13L)), Some(@moondate.Span::new()))
}

///|
test "a budget of zero or less never expires" {
  let d = Deadline::start(@moondate.Span::new(), 0L)
  assert_eq(d.expired(sec(1_000_000L)), false)
  assert_eq(d.remaining(sec(5L)), None)
  let n = Deadline::start(@moondate.Span::new(seconds=-1L), 0L)
  assert_eq(n.expired(sec(5L)), false)
}
