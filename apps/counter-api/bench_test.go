package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
)

// bigHTML is a ~200-link page, closer to a real site than the unit-test fixture.
var bigHTML = func() []byte {
	var b strings.Builder
	b.WriteString("<html><body>")
	for i := 0; i < 200; i++ {
		b.WriteString(`<a href="https://example.com/page">alpha beta gamma</a>`)
		b.WriteString(`<a href="/local">skip me</a>`)
	}
	b.WriteString("</body></html>")
	return []byte(b.String())
}()

func BenchmarkCountLinks(b *testing.B) {
	b.ReportAllocs()
	b.SetBytes(int64(len(bigHTML)))
	for i := 0; i < b.N; i++ {
		if countLinks(bigHTML) != 600 {
			b.Fatal("unexpected count")
		}
	}
}

// BenchmarkGetTagsHandlerCached measures the hot path: a purely synchronous read
// of the pre-serialized snapshot, no fetching, no goroutines, no marshaling.
func BenchmarkGetTagsHandlerCached(b *testing.B) {
	gin.SetMode(gin.ReleaseMode)

	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		_, _ = w.Write(bigHTML)
	}))
	defer origin.Close()

	urls := make([]string, 10)
	for i := range urls {
		urls[i] = origin.URL
	}
	server := newServer(newAnalyzer(Config{URLs: urls, Timeout: 2 * time.Second, RefreshInterval: time.Hour}))
	if !server.refresh(context.Background()) {
		b.Fatal("refresh failed")
	}
	router := buildRouter(server)

	b.ReportAllocs()
	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		req := httptest.NewRequest(http.MethodGet, "/v1/tags", nil)
		for pb.Next() {
			rec := httptest.NewRecorder()
			router.ServeHTTP(rec, req)
			if rec.Code != http.StatusOK {
				b.Fatalf("status %d", rec.Code)
			}
		}
	})
}

func BenchmarkGetTagHandlerCached(b *testing.B) {
	gin.SetMode(gin.ReleaseMode)

	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		_, _ = w.Write(bigHTML)
	}))
	defer origin.Close()

	server := newServer(newAnalyzer(Config{URLs: []string{origin.URL}, Timeout: 2 * time.Second, RefreshInterval: time.Hour}))
	if !server.refresh(context.Background()) {
		b.Fatal("refresh failed")
	}
	router := buildRouter(server)

	b.ReportAllocs()
	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		req := httptest.NewRequest(http.MethodGet, "/v1/tags/0", nil)
		for pb.Next() {
			rec := httptest.NewRecorder()
			router.ServeHTTP(rec, req)
			if rec.Code != http.StatusOK {
				b.Fatalf("status %d", rec.Code)
			}
		}
	})
}
