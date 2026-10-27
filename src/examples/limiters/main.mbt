// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The same forty calls offered to a bucket, a sliding window and a period, all
/// with a quota of twenty a second.
///
/// `moon run src/examples/limiters`
///
/// The traffic is bursty on purpose: one burst every two seconds, forty calls
/// from 950 ms past the second to 1050 ms past it, so the burst straddles a
/// period boundary and nothing else happens in between. That is the shape that
/// tells the three apart:
///
/// - the bucket spends its saved burst, then holds the rate;
/// - the sliding window refuses the twenty-first call in any one-second stretch,
///   wherever that stretch starts;
/// - the period starts a fresh twenty when the second turns over, so the same
///   burst is counted as twenty on each side and all forty pass.
fn main {
  let second = @moondate.Span::new(seconds=1L)
  let bucket = @moonward.Bucket::new(20.0, burst=20.0)
  let sliding = @moonward.Sliding::new(20, second)
  let period = @moonward.Period::new(20, second, align=true)
  println("burst  bucket  sliding  period")
  for b in 0L..<4L {
    let mut by_bucket = 0
    let mut by_sliding = 0
    let mut by_period = 0
    for k in 0L..<40L {
      // 950 ms past the second, 2.5 ms apart: 20 calls either side of the line.
      let now = b * 2_000_000_000L + 950_000_000L + k * 2_500_000L
      if bucket.take(now) {
        by_bucket += 1
      }
      if sliding.take(now) {
        by_sliding += 1
      }
      match period.take(now) {
        @moonward.Over => ()
        _ => by_period += 1
      }
    }
    println(
      "\{pad(b.to_int(), 5)}  \{pad(by_bucket, 6)}  \{pad(by_sliding, 7)}  \{pad(by_period, 6)}",
    )
  }
  // What a caller does with a refusal: ask how long until there is room again,
  // which is the number a Retry-After header carries.
  let wait = bucket.next(7_050_000_000L, n=5.0)
  println("\nfive tokens in \{(wait.nanos + 999_999L) / 1_000_000L} ms")
}

///|
/// Right-align a number in `width` columns, so the table can be read.
fn pad(n : Int32, width : Int32) -> String {
  let mut out = "\{n}"
  while out.length() < width {
    out = " " + out
  }
  out
}
