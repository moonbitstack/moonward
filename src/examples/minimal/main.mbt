// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The smallest working breaker: one backend that fails for a while, one call
/// every 50 ms, and a count of what got through.
///
/// `moon run src/examples/minimal`
fn main {
  let breaker = @moonward.Breaker::new()
  let mut sent = 0
  let mut refused = 0
  for i in 0L..<120L {
    // The clock is ours. 50 ms per step, in nanoseconds.
    let now = i * 50_000_000L
    // A draw from [0, 1). Any real generator will do; this one is a constant so
    // the run prints the same thing every time.
    let roll = (i * 37L % 100L).to_double() / 100.0
    match breaker.allow(now, roll) {
      Some(call) => {
        sent += 1
        if i >= 30L && i < 90L {
          call.fail(now)
        } else {
          call.pass(now)
        }
      }
      None => refused += 1
    }
    if (i + 1L) % 30L == 0L {
      let ratio = (breaker.ratio(now) * 100.0).round().to_int()
      println(
        "\{(i + 1L) * 50L} ms  sent \{sent}  refused \{refused}  ratio \{ratio}%",
      )
      sent = 0
      refused = 0
    }
  }
}
