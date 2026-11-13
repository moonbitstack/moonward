package main

import (
	"strings"
	"time"

	"github.com/juju/ratelimit"
	"golang.org/x/time/rate"
)

// bucketCase is one bucket, the calls made to it in order, and what the
// reference answered.
type bucketCase struct {
	rate    float64
	burst   float64
	times   []int64
	costs   []float64
	granted []bool
	tokens  []float64
}

// ms turns millisecond offsets into the nanoseconds a caller would pass.
func ms(offsets ...int64) []int64 {
	out := make([]int64, len(offsets))
	for i, v := range offsets {
		out[i] = v * 1_000_000
	}
	return out
}

func sec(offsets ...int64) []int64 {
	out := make([]int64, len(offsets))
	for i, v := range offsets {
		out[i] = v * 1_000_000_000
	}
	return out
}

func ones(n int) []float64 {
	out := make([]float64, n)
	for i := range out {
		out[i] = 1
	}
	return out
}

type shape struct {
	rate  float64
	burst int
	times []int64
	costs []float64
}

// continuousShapes are read by the reference that refills between calls, so
// their clock readings fall anywhere, not on a grid.
func continuousShapes() []shape {
	return []shape{
		{2, 5, ms(0, 0, 100, 250, 700, 1000, 1400, 2000, 2600, 3500, 5000, 5300), ones(12)},
		{2.5, 3, ms(0, 0, 0, 0, 200, 400, 650, 900, 1200, 2000, 2100, 3000), []float64{1, 1, 1, 4, 1, 1, 1, 1, 1, 1, 1, 1}},
		{10, 2, ms(0, 0, 0, 50, 100, 150, 300, 450, 600, 1000, 1050, 1100), ones(12)},
		{0.5, 1, sec(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12), ones(12)},
		{1, 3, ms(0, 0, 500, 1500, 2000, 3000, 3500, 4000, 7000, 8000, 11000, 12000), []float64{1, 2, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1}},
		{100, 50, ms(0, 5, 10, 15, 20, 25, 30, 40, 55, 70, 100, 200), ones(12)},
		{3, 4, ms(0, 100, 200, 400, 700, 1000, 1500, 2000, 2100, 2400, 2700, 3000), ones(12)},
		{2, 10, ms(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5000), ones(12)},
		{0.25, 2, sec(0, 0, 1, 3, 5, 7, 9, 11, 13, 15, 17, 19), ones(12)},
		{5, 2, ms(0, 0, 250, 400, 600, 800, 1000, 1200, 1400, 1600, 1800, 2000), ones(12)},
		{50, 100, ms(0, 0, 20, 40, 60, 80, 100, 220, 340, 460, 580, 700), ones(12)},
		{1000, 250, ms(0, 0, 0, 100, 200, 300, 400, 500, 600, 700, 800, 900), ones(12)},
	}
}

// continuousCases asks the reference that carries fractional tokens.
func continuousCases() []bucketCase {
	var out []bucketCase
	for _, s := range continuousShapes() {
		lim := rate.NewLimiter(rate.Limit(s.rate), s.burst)
		c := bucketCase{rate: s.rate, burst: float64(s.burst)}
		for i, offset := range s.times {
			at := base.Add(time.Duration(offset))
			granted := lim.AllowN(at, int(s.costs[i]))
			c.times = append(c.times, offset)
			c.costs = append(c.costs, s.costs[i])
			c.granted = append(c.granted, granted)
			c.tokens = append(c.tokens, lim.TokensAt(at))
		}
		out = append(out, c)
	}
	return out
}

// tickedShapes stay on a two-second grid, which holds a whole number of every
// tick below it — 2 s, 1 s, 500 ms, 400 ms, 250 ms and 100 ms — so a bucket that
// fills a tick at a time and one that fills continuously hold the same number of
// tokens at every reading. Off the grid they part company, which is the price of
// counting in whole ticks.
func tickedShapes() []shape {
	return []shape{
		{0.5, 1, sec(0, 0, 2, 4, 6, 8, 10, 12, 14, 16), ones(10)},
		{1, 3, sec(0, 0, 0, 2, 4, 6, 8, 10, 12, 14), ones(10)},
		{2, 5, sec(0, 0, 2, 4, 4, 6, 8, 10, 12, 14), ones(10)},
		{2.5, 4, sec(0, 0, 2, 4, 4, 6, 8, 10, 12, 14), ones(10)},
		{4, 2, sec(0, 0, 0, 2, 2, 4, 6, 8, 10, 12), ones(10)},
		{10, 30, sec(0, 0, 0, 2, 2, 4, 4, 6, 8, 10), ones(10)},
	}
}

// clock is the reference's view of time, moved by the harness.
type clock struct{ at time.Time }

func (c *clock) Now() time.Time { return c.at }

// Sleep is never reached: no call here waits for a token.
func (c *clock) Sleep(d time.Duration) { c.at = c.at.Add(d) }

// tickedCases asks the reference that fills a tick at a time.
func tickedCases() []bucketCase {
	var out []bucketCase
	for _, s := range tickedShapes() {
		c := &clock{at: base}
		b := ratelimit.NewBucketWithRateAndClock(s.rate, int64(s.burst), c)
		row := bucketCase{rate: s.rate, burst: float64(s.burst)}
		for i, offset := range s.times {
			c.at = base.Add(time.Duration(offset))
			taken := b.TakeAvailable(1)
			row.times = append(row.times, offset)
			row.costs = append(row.costs, s.costs[i])
			row.granted = append(row.granted, taken == 1)
			row.tokens = append(row.tokens, float64(b.Available()))
		}
		out = append(out, row)
	}
	return out
}

// bucketVectors renders both sets, with the tests that replay them.
func bucketVectors() string {
	var b strings.Builder
	b.WriteString(header)
	b.WriteString(`///|
/// One bucket, the calls made to it in order, and what a bucket that refills
/// between calls answered: whether each call went through, and what was left
/// when it returned.
///|
priv struct BucketVector {
  rate : Double
  burst : Double
  times : Array[Int64]
  costs : Array[Double]
  granted : Array[Bool]
  tokens : Array[Double]
}

///|
fn bucket_vectors_continuous() -> Array[BucketVector] {
  [
`)
	writeBucketRows(&b, continuousCases())
	b.WriteString(`  ]
}

///|
fn bucket_vectors_ticked() -> Array[BucketVector] {
  [
`)
	writeBucketRows(&b, tickedCases())
	b.WriteString(`  ]
}
`)
	return b.String()
}

func writeBucketRows(b *strings.Builder, cases []bucketCase) {
	for _, c := range cases {
		b.WriteString("    {\n")
		b.WriteString("      rate: " + num(c.rate) + ",\n")
		b.WriteString("      burst: " + num(c.burst) + ",\n")
		b.WriteString("      times: " + nanos_list(c.times) + ",\n")
		b.WriteString("      costs: " + nums(c.costs) + ",\n")
		b.WriteString("      granted: " + bools(c.granted) + ",\n")
		b.WriteString("      tokens: " + nums(c.tokens) + ",\n")
		b.WriteString("    },\n")
	}
}
