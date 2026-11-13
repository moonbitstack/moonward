package main

import (
	"strings"
	"time"

	iterated "github.com/cenkalti/backoff/v5"
	powered "github.com/jpillora/backoff"
)

// backoffShape is one schedule: the wait before the first retry, what each wait
// is multiplied by, and the ceiling.
type backoffShape struct {
	baseMs int64
	factor float64
	capMs  int64
}

func backoffShapes() []backoffShape {
	return []backoffShape{
		{100, 2, 1000},
		{50, 1.5, 400},
		{1000, 3, 10000},
		{20, 4, 1000},
		{500, 2, 5000},
		{10, 10, 100000},
		{200, 1.2, 600},
		{100, 2, 100000},
	}
}

const attempts = 8

// iteratedCeilings asks the reference that multiplies its interval forward,
// with randomness turned off so the schedule itself is what comes back.
func iteratedCeilings() [][]int64 {
	out := make([][]int64, 0, len(backoffShapes()))
	for _, s := range backoffShapes() {
		b := iterated.NewExponentialBackOff()
		b.InitialInterval = time.Duration(s.baseMs) * time.Millisecond
		b.MaxInterval = time.Duration(s.capMs) * time.Millisecond
		b.Multiplier = s.factor
		b.RandomizationFactor = 0
		b.Reset()
		row := make([]int64, 0, attempts)
		for i := 0; i < attempts; i++ {
			row = append(row, int64(b.NextBackOff()))
		}
		out = append(out, row)
	}
	return out
}

// poweredCeilings asks the reference that raises the factor to the attempt
// number, which is the same schedule computed a different way.
func poweredCeilings() [][]int64 {
	out := make([][]int64, 0, len(backoffShapes()))
	for _, s := range backoffShapes() {
		b := &powered.Backoff{
			Min:    time.Duration(s.baseMs) * time.Millisecond,
			Max:    time.Duration(s.capMs) * time.Millisecond,
			Factor: s.factor,
			Jitter: false,
		}
		row := make([]int64, 0, attempts)
		for i := 0; i < attempts; i++ {
			row = append(row, int64(b.ForAttempt(float64(i))))
		}
		out = append(out, row)
	}
	return out
}

func backoffVectors() string {
	var b strings.Builder
	b.WriteString(header)
	b.WriteString(`///|
/// One schedule — the wait before the first retry, what each wait is multiplied
/// by, and the ceiling — with the waits a reference computed for the first
/// ` + "`attempts`" + ` retries.
///|
priv struct BackoffVector {
  base : Int64
  factor : Double
  cap : Int64
  waits : Array[Int64]
}

///|
fn backoff_vectors_iterated() -> Array[BackoffVector] {
  [
`)
	writeBackoffRows(&b, iteratedCeilings())
	b.WriteString(`  ]
}

///|
fn backoff_vectors_powered() -> Array[BackoffVector] {
  [
`)
	writeBackoffRows(&b, poweredCeilings())
	b.WriteString(`  ]
}
`)
	return b.String()
}

func writeBackoffRows(b *strings.Builder, rows [][]int64) {
	for i, waits := range rows {
		s := backoffShapes()[i]
		b.WriteString("    {\n")
		b.WriteString("      base: " + nanos(s.baseMs*1_000_000) + ",\n")
		b.WriteString("      factor: " + num(s.factor) + ",\n")
		b.WriteString("      cap: " + nanos(s.capMs*1_000_000) + ",\n")
		b.WriteString("      waits: " + nanos_list(waits) + ",\n")
		b.WriteString("    },\n")
	}
}
