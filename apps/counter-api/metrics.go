package main

import (
	"errors"
	"log"
	"net/http"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Metrics are registered on the default registry, which also carries the Go
// runtime and process collectors. They are served on their own port (see
// serveMetrics) so /metrics is never reachable through the public Gateway.
var (
	httpRequestsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "counter_api_http_requests_total",
		Help: "HTTP requests served, by method, route template and status code.",
	}, []string{"method", "route", "status"})

	httpRequestDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name: "counter_api_http_request_duration_seconds",
		Help: "Time spent serving an HTTP request, by method and route template.",
		// Starts at 50µs: the cached read path answers in well under 1ms, and
		// with a 0.5ms first bucket every quantile collapsed to 0.
		Buckets: []float64{.00005, .0001, .00025, .0005, .001, .0025, .005, .01, .025, .05, .1, .25, .5, 1},
	}, []string{"method", "route"})

	refreshesTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "counter_api_refreshes_total",
		Help: "Snapshot refreshes, by result: completed, or skipped because one was already running.",
	}, []string{"result"})

	refreshDuration = promauto.NewHistogram(prometheus.HistogramOpts{
		Name:    "counter_api_refresh_duration_seconds",
		Help:    "Time taken to fetch every target URL and swap in a new snapshot.",
		Buckets: []float64{.1, .25, .5, 1, 2.5, 5, 10, 20, 30},
	})

	lastRefreshTimestamp = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "counter_api_last_refresh_timestamp_seconds",
		Help: "Unix time of the last completed refresh.",
	})

	urlLinkWords = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "counter_api_url_link_words",
		Help: "Words inside absolute links counted on each target URL in the last refresh.",
	}, []string{"url"})

	urlFetchDuration = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "counter_api_url_fetch_duration_seconds",
		Help: "Time taken to fetch and count each target URL in the last refresh.",
	}, []string{"url"})
)

// metricsMiddleware records request count and latency. It labels by the route
// template (c.FullPath), not the raw path, so /v1/tags/:url_id stays one series.
func metricsMiddleware(c *gin.Context) {
	started := time.Now()
	c.Next()
	route := c.FullPath()
	if route == "" {
		route = "unmatched"
	}
	httpRequestsTotal.WithLabelValues(c.Request.Method, route, strconv.Itoa(c.Writer.Status())).Inc()
	httpRequestDuration.WithLabelValues(c.Request.Method, route).Observe(time.Since(started).Seconds())
}

func recordRefresh(results []TagResult, took time.Duration) {
	refreshesTotal.WithLabelValues("completed").Inc()
	refreshDuration.Observe(took.Seconds())
	lastRefreshTimestamp.SetToCurrentTime()
	for _, result := range results {
		urlLinkWords.WithLabelValues(result.URL).Set(float64(result.Count))
		urlFetchDuration.WithLabelValues(result.URL).Set(result.Time)
	}
}

// serveMetrics exposes /metrics on addr until the process exits. A failure here
// is logged, not fatal: losing metrics must not take the API down.
func serveMetrics(addr string) {
	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.Handler())
	server := &http.Server{Addr: addr, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	log.Printf("metrics listening on %s", addr)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Printf("metrics server stopped: %v", err)
	}
}
