// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Seconds, as the nanoseconds the clock is read in.
fn sec(n : Int64) -> Int64 {
  n * 1_000_000_000L
}

///|
/// Milliseconds, as the nanoseconds the clock is read in.
fn ms(n : Int64) -> Int64 {
  n * 1_000_000L
}
