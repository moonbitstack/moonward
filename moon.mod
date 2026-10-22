name = "moonbitstack/moonward"

version = "0.2.0"

readme = "README.md"

repository = "https://github.com/moonbitstack/moonward"

license = "Apache-2.0"

keywords = [
  "resilience",
  "circuit-breaker",
  "rate-limit",
  "load-shedding",
  "backoff",
  "retry",
  "moonbit",
]

description = "Resilience without I/O: circuit breaking, rate limiting, adaptive load shedding, backoff, rolling windows and deadlines, with the clock and the randomness passed in."

preferred_target = "wasm-gc"

source = "src"

import {
  "moonbitstack/moondate@0.1.0",
}
