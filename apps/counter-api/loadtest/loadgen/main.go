// Command loadgen is a dependency-free constant-arrival-rate load generator.
// Use it when k6 / vegeta aren't installed.
//
//	go run ./loadtest/loadgen                                  # 5000 rps for 60s
//	go run ./loadtest/loadgen -rate 8000 -duration 30s -url http://host:8080
//
// It launches requests at a fixed rate regardless of how fast responses come
// back (open model): a server that can't keep up shows up as "dropped" requests
// (the arrival schedule slipped) and rising latency, not as a silently lowered
// send rate.
package main

import (
	"flag"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"os"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

func main() {
	var (
		base      = flag.String("url", "http://localhost:8080", "base URL of counter-api")
		rate      = flag.Int("rate", 5000, "requests per second to launch")
		duration  = flag.Duration("duration", 60*time.Second, "attack duration")
		timeout   = flag.Duration("timeout", 5*time.Second, "per-request timeout")
		workers   = flag.Int("workers", 512, "max concurrent in-flight requests")
		singlePct = flag.Int("single-pct", 10, "percent of traffic hitting /v1/tags/{id} instead of /v1/tags")
	)
	flag.Parse()

	transport := &http.Transport{
		MaxIdleConns:        *workers * 2,
		MaxIdleConnsPerHost: *workers * 2,
		MaxConnsPerHost:     *workers * 2,
		IdleConnTimeout:     90 * time.Second,
	}
	client := &http.Client{Timeout: *timeout, Transport: transport}

	// One token per scheduled request; buffer ~1s so a brief stall doesn't
	// immediately count as dropped.
	tokens := make(chan string, *rate)
	var (
		sent    int64
		dropped int64
		done    int64
		errs    int64
	)
	statusTally := sync.Map{} // int -> *int64
	latencies := make([]time.Duration, 0, *rate*int((*duration)/time.Second+1))
	var latMu sync.Mutex

	// Workers.
	var wg sync.WaitGroup
	for i := 0; i < *workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for url := range tokens {
				start := time.Now()
				req, _ := http.NewRequest(http.MethodGet, url, nil)
				resp, err := client.Do(req)
				elapsed := time.Since(start)
				latMu.Lock()
				latencies = append(latencies, elapsed)
				latMu.Unlock()
				atomic.AddInt64(&done, 1)
				if err != nil {
					atomic.AddInt64(&errs, 1)
					continue
				}
				io.Copy(io.Discard, resp.Body)
				resp.Body.Close()
				ctr, _ := statusTally.LoadOrStore(resp.StatusCode, new(int64))
				atomic.AddInt64(ctr.(*int64), 1)
				if resp.StatusCode != http.StatusOK {
					atomic.AddInt64(&errs, 1)
				}
			}
		}()
	}

	// Dispatcher: self-correcting open-model schedule. Each pass computes how
	// many requests *should* have been launched by now (elapsed * rate) and
	// releases the shortfall, so a missed OS timer tick is caught up rather
	// than silently lowering the send rate.
	tagsURL := *base + "/v1/tags"

	fmt.Printf("attacking %s at %d rps for %s (%d workers)\n", *base, *rate, *duration, *workers)
	wallStart := time.Now()
	sendDeadline := wallStart.Add(*duration)
	for {
		now := time.Now()
		if !now.Before(sendDeadline) {
			break
		}
		target := int64(now.Sub(wallStart).Seconds() * float64(*rate))
		for atomic.LoadInt64(&sent) < target {
			url := tagsURL
			if rand.Intn(100) < *singlePct {
				url = fmt.Sprintf("%s/v1/tags/%d", *base, rand.Intn(10))
			}
			atomic.AddInt64(&sent, 1)
			select {
			case tokens <- url:
			default:
				atomic.AddInt64(&dropped, 1)
			}
		}
		time.Sleep(200 * time.Microsecond)
	}
	sendWall := time.Since(wallStart)
	close(tokens)
	wg.Wait()
	wall := time.Since(wallStart)

	// Report.
	latMu.Lock()
	sort.Slice(latencies, func(i, j int) bool { return latencies[i] < latencies[j] })
	lat := latencies
	latMu.Unlock()

	pct := func(p float64) time.Duration {
		if len(lat) == 0 {
			return 0
		}
		idx := int(p / 100 * float64(len(lat)))
		if idx >= len(lat) {
			idx = len(lat) - 1
		}
		return lat[idx]
	}
	var sum time.Duration
	for _, d := range lat {
		sum += d
	}
	mean := time.Duration(0)
	if len(lat) > 0 {
		mean = sum / time.Duration(len(lat))
	}

	fmt.Printf("\nsend window      %s   (drain +%s)\n", sendWall.Round(time.Millisecond), (wall - sendWall).Round(time.Millisecond))
	fmt.Printf("scheduled        %d  (%.0f rps launched)\n", atomic.LoadInt64(&sent), float64(atomic.LoadInt64(&sent))/sendWall.Seconds())
	fmt.Printf("completed        %d  (%.0f rps achieved)\n", atomic.LoadInt64(&done), float64(atomic.LoadInt64(&done))/wall.Seconds())
	fmt.Printf("dropped          %d  (send schedule slipped - server too slow / backlog full)\n", atomic.LoadInt64(&dropped))
	fmt.Printf("errors/non-200   %d\n", atomic.LoadInt64(&errs))
	fmt.Print("status codes     ")
	statusTally.Range(func(k, v any) bool {
		fmt.Printf("%d=%d  ", k.(int), atomic.LoadInt64(v.(*int64)))
		return true
	})
	fmt.Printf("\n\nlatency  min %s  mean %s  p50 %s  p90 %s  p95 %s  p99 %s  max %s\n",
		d(lat, 0), mean.Round(time.Microsecond),
		pct(50).Round(time.Microsecond), pct(90).Round(time.Microsecond),
		pct(95).Round(time.Microsecond), pct(99).Round(time.Microsecond),
		dLast(lat).Round(time.Microsecond))

	if atomic.LoadInt64(&dropped) > 0 || atomic.LoadInt64(&errs) > 0 {
		os.Exit(1)
	}
}

func d(s []time.Duration, i int) time.Duration {
	if len(s) == 0 {
		return 0
	}
	return s[i].Round(time.Microsecond)
}

func dLast(s []time.Duration) time.Duration {
	if len(s) == 0 {
		return 0
	}
	return s[len(s)-1]
}
