package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
)

const sampleHTML = `<a href="https://one.example">one two</a><a href="/relative">ignored words</a><a href='http://two.example'>three</a>`

// newWarmServer builds a Server whose targets all point at a local stub origin
// and performs one synchronous refresh, so the snapshot is populated.
func newWarmServer(t *testing.T, html string, urlCount int) (*Server, *int64) {
	t.Helper()
	var hits int64
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		atomic.AddInt64(&hits, 1)
		w.Header().Set("Content-Type", "text/html")
		_, _ = w.Write([]byte(html))
	}))
	t.Cleanup(origin.Close)

	urls := make([]string, urlCount)
	for i := range urls {
		urls[i] = origin.URL
	}
	server := newServer(newAnalyzer(Config{URLs: urls, Timeout: 2 * time.Second, RefreshInterval: time.Hour}))
	if !server.refresh(context.Background()) {
		t.Fatal("initial refresh did not run")
	}
	return server, &hits
}

func TestHealthcheck(t *testing.T) {
	gin.SetMode(gin.TestMode)
	server := newServer(newAnalyzer(Config{URLs: []string{"https://example.com"}, Timeout: time.Second}))
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/healthcheck", nil)
	buildRouter(server).ServeHTTP(recorder, request)
	if recorder.Code != http.StatusOK || recorder.Body.String() != `{"data":"Ok!"}` {
		t.Fatalf("unexpected health response: %d %s", recorder.Code, recorder.Body.String())
	}
}

func TestDocsRedirect(t *testing.T) {
	gin.SetMode(gin.TestMode)
	server := newServer(newAnalyzer(Config{URLs: []string{"https://example.com"}, Timeout: time.Second}))
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/docs", nil)
	buildRouter(server).ServeHTTP(recorder, request)
	if recorder.Code != http.StatusPermanentRedirect || recorder.Header().Get("Location") != "/swagger/index.html" {
		t.Fatalf("unexpected docs redirect: %d %s", recorder.Code, recorder.Header().Get("Location"))
	}
}

func TestCountURL(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		response.Header().Set("Content-Type", "text/html")
		_, _ = response.Write([]byte(sampleHTML))
	}))
	defer server.Close()

	analyzer := newAnalyzer(Config{URLs: []string{server.URL}, Timeout: time.Second})
	if count := analyzer.countURL(context.Background(), server.URL); count != 3 {
		t.Fatalf("expected 3 words in absolute links, got %d", count)
	}
}

func TestCountLinks(t *testing.T) {
	if got := countLinks([]byte(sampleHTML)); got != 3 {
		t.Fatalf("expected 3, got %d", got)
	}
	if got := countLinks(nil); got != 0 {
		t.Fatalf("expected 0 for empty body, got %d", got)
	}
}

func TestInvalidTagID(t *testing.T) {
	gin.SetMode(gin.TestMode)
	server, _ := newWarmServer(t, sampleHTML, 1)
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/v1/tags/10", nil)
	buildRouter(server).ServeHTTP(recorder, request)
	if recorder.Code != http.StatusUnprocessableEntity || !strings.Contains(recorder.Body.String(), "id must be between") {
		t.Fatalf("unexpected invalid id response: %d %s", recorder.Code, recorder.Body.String())
	}
}

func TestTagsHandlerServesSnapshot(t *testing.T) {
	gin.SetMode(gin.TestMode)
	server, _ := newWarmServer(t, sampleHTML, 4)
	recorder := httptest.NewRecorder()
	buildRouter(server).ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/v1/tags", nil))
	if recorder.Code != http.StatusOK {
		t.Fatalf("unexpected status: %d", recorder.Code)
	}
	var body TagsResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
		t.Fatalf("bad json: %v", err)
	}
	if body.URLsProcessed != 4 || len(body.Data) != 4 {
		t.Fatalf("expected 4 urls, got %d / %d", body.URLsProcessed, len(body.Data))
	}
	for _, item := range body.Data {
		if item.Count != 3 {
			t.Fatalf("expected count 3 per url, got %d", item.Count)
		}
	}
}

func TestTagsHandlerBeforeWarmup(t *testing.T) {
	gin.SetMode(gin.TestMode)
	server := newServer(newAnalyzer(Config{URLs: []string{"https://example.com"}, Timeout: time.Second}))
	recorder := httptest.NewRecorder()
	buildRouter(server).ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/v1/tags", nil))
	if recorder.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503 before first refresh, got %d", recorder.Code)
	}
}

func TestRefreshSingleFlight(t *testing.T) {
	server, _ := newWarmServer(t, sampleHTML, 2)

	// Hold the refresh lock so a concurrent refresh must bail out immediately.
	server.refreshMu.Lock()
	var ran atomic.Bool
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		ran.Store(server.refresh(context.Background()))
	}()
	wg.Wait()
	server.refreshMu.Unlock()

	if ran.Load() {
		t.Fatal("refresh ran while another was in flight")
	}
}

func TestClearCacheTriggersRefresh(t *testing.T) {
	gin.SetMode(gin.TestMode)
	server, hits := newWarmServer(t, sampleHTML, 2)
	before := atomic.LoadInt64(hits)

	recorder := httptest.NewRecorder()
	buildRouter(server).ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/v1/cache/clear", nil))
	if recorder.Code != http.StatusOK {
		t.Fatalf("unexpected status: %d", recorder.Code)
	}

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if atomic.LoadInt64(hits) > before {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("cache clear did not trigger a background refresh")
}
