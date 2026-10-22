// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A time budget measured from the instant it started.
///
/// A budget of zero or less never expires, which is how go-zero, gRPC and most
/// servers spell "no timeout": a configuration that leaves the timeout unset
/// should not time everything out at once.
pub struct Deadline {
  start : Int64
  budget : Int64
}

///|
/// A deadline of `budget` starting at `now`.
pub fn Deadline::start(budget : @moondate.Span, now : Int64) -> Deadline {
  { start: now, budget: budget.nanos, }
}

///|
/// Whether the budget is spent at `now`.
pub fn Deadline::expired(self : Deadline, now : Int64) -> Bool {
  self.budget > 0L && now - self.start >= self.budget
}

///|
/// What is left of the budget at `now`, never negative. `None` when there is no
/// budget, which has no finite remainder.
pub fn Deadline::remaining(self : Deadline, now : Int64) -> @moondate.Span? {
  guard self.budget > 0L else { None }
  let left = self.budget - (now - self.start)
  Some({ nanos: if left < 0L { 0L } else { left }, })
}
