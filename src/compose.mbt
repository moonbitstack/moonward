// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Limiters put together: one per caller, and several in a row. Both work on any limiter
// that can hand out one permit and take it back, which is what `Permit` asks.

///|
/// Something that admits one call at a time and can take an admission back.
///
/// The four limiters here implement it. Implement it for your own, and it can be
/// partitioned and chained like them.
pub(open) trait Permit {
  /// Admit one call at `now`, or refuse it without counting it.
  fn acquire(Self, now : Int64) -> Bool
  /// Take back the call admitted last, as if it had never been admitted.
  fn release(Self, now : Int64) -> Unit
}

///|
/// One token, refunded up to the burst.
pub impl Permit for Bucket with fn acquire(self, now) {
  self.take(now)
}

///|
pub impl Permit for Bucket with fn release(self, now) {
  let state = self.step(self.state, now, n=0.0).state
  let tokens = state.tokens + 1.0
  self.state = {
    tokens: if tokens > self.burst {
      self.burst
    } else {
      tokens
    },
    at: state.at,
  }
}

///|
pub extend Bucket with Permit::{acquire, release}

///|
/// One event of the period; a refused one is not counted.
pub impl Permit for Period with fn acquire(self, now) {
  let counted = self.step(self.state, now)
  if counted.quota is Over {
    // The state is the period the refusal saw, without the refused event in it.
    self.state = { ..counted.state, used: counted.state.used - 1, }
    false
  } else {
    self.state = counted.state
    true
  }
}

///|
pub impl Permit for Period with fn release(self, now) {
  let state = self.rolled(self.state, now)
  self.state = {
    ..state,
    used: if state.used > 0 {
      state.used - 1
    } else {
      0
    },
  }
}

///|
pub extend Period with Permit::{acquire, release}

///|
pub impl Permit for Sliding with fn acquire(self, now) {
  self.take(now)
}

///|
/// The latest stamp goes, which is the one the last admission added.
pub impl Permit for Sliding with fn release(self, _now) {
  ignore(self.stamps.pop())
}

///|
pub extend Sliding with Permit::{acquire, release}

///|
pub impl Permit for Gate with fn acquire(self, _now) {
  self.enter()
}

///|
pub impl Permit for Gate with fn release(self, _now) {
  self.leave()
}

///|
pub extend Gate with Permit::{acquire, release}

///|
/// Several limiters a call has to get past, in order: a per-second rate and a daily
/// quota, a quota and a concurrency gate. Any refusal refuses the call, and the
/// permits already taken from the limiters before it are given back, so a call
/// that does not run spends nothing.
pub struct Chained {
  links : Array[&Permit]
}

///|
/// The limiters in the order a call meets them. With none, every call passes.
pub fn Chained::new(links : Array[&Permit]) -> Chained {
  { links, }
}

///|
pub impl Permit for Chained with fn acquire(self, now) {
  for i, link in self.links {
    if !link.acquire(now) {
      for j = i - 1; j >= 0; j = j - 1 {
        self.links[j].release(now)
      }
      return false
    }
  }
  true
}

///|
pub impl Permit for Chained with fn release(self, now) {
  for j = self.links.length() - 1; j >= 0; j = j - 1 {
    self.links[j].release(now)
  }
}

///|
pub extend Chained with Permit::{acquire, release}

///|
/// The most keys a [`Partitioned`] keeps a limiter for unless told otherwise. No
/// common default exists for this; a bound is the safe side, since a key per client
/// address would otherwise grow without end, and ten thousand limiters of a few
/// words each fit in well under a megabyte.
pub let partitions : Int32 = 10000

///|
/// A limiter per key: per client, per tenant, per route. `make` builds the limiter
/// for a key the first time it is seen. At most `limit` keys are kept; past that the
/// one used least recently is dropped, and comes back fresh if it is seen again.
pub struct Partitioned[L] {
  make : (String) -> L
  limit : Int32
  // Insertion order is use order: a key is moved to the end each time it is used.
  entries : Map[String, L]
}

///|
/// No key seen yet.
///
/// # Parameters
/// - `make` : the limiter for a key seen for the first time
/// - `limit` : the most keys kept, [`partitions`] unless given; at least one
pub fn[L] Partitioned::new(
  make : (String) -> L,
  limit~ : Int32 = partitions,
) -> Partitioned[L] {
  { make, limit: if limit < 1 { 1 } else { limit }, entries: Map([]), }
}

///|
/// The limiter for `key`, made if this is the first time, and marked as used now.
pub fn[L] Partitioned::get(self : Partitioned[L], key : String) -> L {
  match self.entries.get(key) {
    Some(limiter) => {
      self.entries.remove(key)
      self.entries[key] = limiter
      limiter
    }
    None => {
      let limiter = (self.make)(key)
      self.entries[key] = limiter
      if self.entries.length() > self.limit {
        if self.entries.keys().next() is Some(oldest) {
          self.entries.remove(oldest)
        }
      }
      limiter
    }
  }
}

///|
/// How many keys have a limiter now.
pub fn[L] Partitioned::length(self : Partitioned[L]) -> Int32 {
  self.entries.length()
}

///|
/// Admit one call for `key` at `now`.
pub fn[L : Permit] Partitioned::acquire(
  self : Partitioned[L],
  key : String,
  now : Int64,
) -> Bool {
  self.get(key).acquire(now)
}

///|
/// Take back the call last admitted for `key`.
pub fn[L : Permit] Partitioned::release(
  self : Partitioned[L],
  key : String,
  now : Int64,
) -> Unit {
  self.get(key).release(now)
}
