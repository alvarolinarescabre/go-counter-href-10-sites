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

func testRouter(analyzer *Analyzer) *gin.Engine {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.GET("/", indexHandler)
	router.GET("/healthcheck", healthHandler)
	router.GET("/v1/tags", getTagsHandler(analyzer))
	router.GET("/v1/tags/:url_id", getTagHandler(analyzer))
	router.GET("/docs", func(c *gin.Context) {
		c.Redirect(http.StatusPermanentRedirect, "/swagger/index.html")
	})
	return router
}

func TestHealthcheck(t *testing.T) {
	router := testRouter(newAnalyzer(Config{URLs: []string{"https://example.com"}, Timeout: time.Second}))
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/healthcheck", nil)
	router.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusOK || recorder.Body.String() != `{"data":"Ok!"}` {
		t.Fatalf("unexpected health response: %d %s", recorder.Code, recorder.Body.String())
	}
}

func TestDocsRedirect(t *testing.T) {
	router := testRouter(newAnalyzer(Config{URLs: []string{"https://example.com"}, Timeout: time.Second}))
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/docs", nil)
	router.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusPermanentRedirect || recorder.Header().Get("Location") != "/swagger/index.html" {
		t.Fatalf("unexpected docs redirect: %d %s", recorder.Code, recorder.Header().Get("Location"))
	}
}

func TestCountURL(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		response.Header().Set("Content-Type", "text/html")
		_, _ = response.Write([]byte(`<a href="https://one.example">one two</a><a href="/relative">ignored words</a><a href='http://two.example'>three</a>`))
	}))
	defer server.Close()

	analyzer := newAnalyzer(Config{URLs: []string{server.URL}, Timeout: time.Second})
	if count := analyzer.countURL(context.Background(), server.URL); count != 3 {
		t.Fatalf("expected 3 words in absolute links, got %d", count)
	}
}

func TestInvalidTagID(t *testing.T) {
	analyzer := newAnalyzer(Config{URLs: []string{"https://example.com"}, Timeout: time.Second})
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/v1/tags/10", nil)
	testRouter(analyzer).ServeHTTP(recorder, request)
	if recorder.Code != http.StatusUnprocessableEntity || !strings.Contains(recorder.Body.String(), "id must be between") {
		t.Fatalf("unexpected invalid id response: %d %s", recorder.Code, recorder.Body.String())
	}
}
