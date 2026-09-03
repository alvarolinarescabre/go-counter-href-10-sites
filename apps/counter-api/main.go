package main

// @title Counter HREF API
// @version 2.0
// @description Counts words inside links with absolute HTTP(S) hrefs.
// @BasePath /
// @schemes http https

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	_ "github.com/alvarolinarescabre/go-counter-href-10-sites/apps/counter-api/docs"
	"github.com/gin-gonic/gin"
	swaggerFiles "github.com/swaggo/files"
	ginSwagger "github.com/swaggo/gin-swagger"
)

const (
	defaultRefreshInterval = 60 * time.Second
	defaultHTTPTimeout     = 10 * time.Second
	maxBodyBytes           = 4 << 20 // cap each fetched page at 4 MiB
	fetchRetries           = 3
)

var hrefPattern = regexp.MustCompile(`(?is)<a\s+[^>]*href\s*=\s*["']https?://[^"']*["'][^>]*>(.*?)</a>`)

type Config struct {
	URLs            []string
	Timeout         time.Duration
	RefreshInterval time.Duration
}

type TagResult struct {
	URLID int     `json:"url_id" example:"0"`
	URL   string  `json:"url" example:"https://go.dev"`
	Count int     `json:"count" example:"42"`
	Time  float64 `json:"time,omitempty" example:"0.1234"`
}

type TagsResponse struct {
	Data          []TagResult `json:"data"`
	TotalTime     float64     `json:"total_time" example:"1.2345"`
	URLsProcessed int         `json:"urls_processed" example:"10"`
}

type MessageResponse struct {
	Data string `json:"data" example:"Ok!"`
}

type Analyzer struct {
	config Config
	client *http.Client
}

func loadConfig() Config {
	urls := strings.Split(os.Getenv("TARGET_URLS"), ",")
	if len(urls) == 1 && strings.TrimSpace(urls[0]) == "" {
		urls = []string{"https://go.dev", "https://www.python.org", "https://www.realpython.com", "https://nodejs.org", "https://www.port.io", "https://www.gitlab.com", "https://www.youtube.com", "https://www.mozilla.org", "https://www.github.com", "https://www.google.com"}
	}
	for index := range urls {
		urls[index] = strings.TrimSpace(urls[index])
	}
	config := Config{URLs: urls, Timeout: defaultHTTPTimeout, RefreshInterval: defaultRefreshInterval}
	if value, err := strconv.Atoi(os.Getenv("HTTP_TIMEOUT_SECONDS")); err == nil && value > 0 {
		config.Timeout = time.Duration(value) * time.Second
	}
	if value, err := strconv.Atoi(os.Getenv("REFRESH_INTERVAL_SECONDS")); err == nil && value > 0 {
		config.RefreshInterval = time.Duration(value) * time.Second
	}
	return config
}

func newAnalyzer(config Config) *Analyzer {
	// Connection pool tuned so keep-alive sockets to the fixed target hosts
	// survive between refresh cycles (no repeated TLS handshake per cycle).
	transport := &http.Transport{
		Proxy: http.ProxyFromEnvironment,
		DialContext: (&net.Dialer{
			Timeout:   5 * time.Second,
			KeepAlive: 30 * time.Second,
		}).DialContext,
		ForceAttemptHTTP2:     true,
		MaxIdleConns:          100,
		MaxIdleConnsPerHost:   8,
		MaxConnsPerHost:       16,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   5 * time.Second,
		ExpectContinueTimeout: time.Second,
		ResponseHeaderTimeout: config.Timeout,
		TLSClientConfig:       &tls.Config{MinVersion: tls.VersionTLS12},
	}
	return &Analyzer{config: config, client: &http.Client{Timeout: config.Timeout, Transport: transport}}
}

func (a *Analyzer) countURL(ctx context.Context, url string) int {
	var body []byte
	for attempt := 0; attempt < fetchRetries; attempt++ {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			return 0
		}
		req.Header.Set("User-Agent", "Mozilla/5.0 (compatible; CounterAPI/2.0)")
		req.Header.Set("Accept", "text/html,application/xhtml+xml")
		response, requestErr := a.client.Do(req)
		if requestErr == nil {
			body, err = io.ReadAll(io.LimitReader(response.Body, maxBodyBytes))
			_, _ = io.Copy(io.Discard, response.Body) // drain the rest so the socket can be reused
			response.Body.Close()
			if err == nil && response.StatusCode < http.StatusBadRequest {
				break
			}
			body = nil
		}
		if attempt < fetchRetries-1 {
			select {
			case <-ctx.Done():
				return 0
			case <-time.After(time.Duration(1<<attempt) * 100 * time.Millisecond):
			}
		}
	}
	return countLinks(body)
}

// countLinks counts whitespace-separated words inside every <a> whose href is an
// absolute HTTP(S) URL. It works on the raw bytes to avoid converting each match
// to a string.
func countLinks(body []byte) int {
	count := 0
	for _, match := range hrefPattern.FindAllSubmatch(body, -1) {
		count += len(bytes.Fields(match[1]))
	}
	return count
}

func (a *Analyzer) analyze(ctx context.Context, urlID int) TagResult {
	url := a.config.URLs[urlID]
	started := time.Now()
	count := a.countURL(ctx, url)
	return TagResult{URLID: urlID, URL: url, Count: count, Time: roundDuration(time.Since(started))}
}

func (a *Analyzer) analyzeAll(ctx context.Context) []TagResult {
	results := make([]TagResult, len(a.config.URLs))
	var waitGroup sync.WaitGroup
	for index := range a.config.URLs {
		waitGroup.Add(1)
		go func(index int) {
			defer waitGroup.Done()
			results[index] = a.analyze(ctx, index)
		}(index)
	}
	waitGroup.Wait()
	return results
}

// Snapshot is an immutable, pre-serialized view of the last successful refresh.
// Request handlers only ever read one; they never fetch or marshal.
type Snapshot struct {
	tagsJSON []byte
	tagJSON  [][]byte
	results  []TagResult
	total    float64
	updated  time.Time
}

// Server owns the background refresher and serves cached snapshots.
type Server struct {
	analyzer  *Analyzer
	interval  time.Duration
	current   atomic.Pointer[Snapshot]
	refreshMu sync.Mutex // guarantees a single in-flight refresh
}

func newServer(analyzer *Analyzer) *Server {
	interval := analyzer.config.RefreshInterval
	if interval <= 0 {
		interval = defaultRefreshInterval
	}
	return &Server{analyzer: analyzer, interval: interval}
}

// refresh fetches every target once and atomically swaps in a new snapshot.
// It returns false (without doing work) when another refresh is already running,
// so callers keep serving the previous snapshot instead of piling up.
func (s *Server) refresh(ctx context.Context) bool {
	if !s.refreshMu.TryLock() {
		return false
	}
	defer s.refreshMu.Unlock()

	started := time.Now()
	results := s.analyzer.analyzeAll(ctx)
	total := roundDuration(time.Since(started))

	tagJSON := make([][]byte, len(results))
	for i := range results {
		tagJSON[i], _ = json.Marshal(results[i])
	}
	tagsJSON, _ := json.Marshal(TagsResponse{Data: results, TotalTime: total, URLsProcessed: len(results)})

	s.current.Store(&Snapshot{
		tagsJSON: tagsJSON,
		tagJSON:  tagJSON,
		results:  results,
		total:    total,
		updated:  time.Now(),
	})
	return true
}

// run drives the periodic refresh until ctx is cancelled.
func (s *Server) run(ctx context.Context) {
	ticker := time.NewTicker(s.interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.refresh(ctx)
		}
	}
}

// index godoc
// @Summary API navigation
// @Tags system
// @Produce json
// @Success 200 {object} MessageResponse
// @Router / [get]
func indexHandler(c *gin.Context) {
	c.JSON(http.StatusOK, MessageResponse{Data: "/v1/tags | /docs | /healthcheck | /v1/cache/clear"})
}

// healthHandler godoc
// @Summary Health check
// @Tags system
// @Produce json
// @Success 200 {object} MessageResponse
// @Router /healthcheck [get]
func healthHandler(c *gin.Context) {
	c.JSON(http.StatusOK, MessageResponse{Data: "Ok!"})
}

// getTagHandler godoc
// @Summary Count links for one configured URL
// @Tags tags
// @Produce json
// @Param url_id path int true "Configured URL index" minimum(0) maximum(9)
// @Success 200 {object} TagResult
// @Failure 422 {object} MessageResponse
// @Failure 503 {object} MessageResponse
// @Router /v1/tags/{url_id} [get]
func (s *Server) getTagHandler(c *gin.Context) {
	snapshot := s.current.Load()
	if snapshot == nil {
		c.JSON(http.StatusServiceUnavailable, MessageResponse{Data: "cache warming up, retry shortly"})
		return
	}
	urlID, err := strconv.Atoi(c.Param("url_id"))
	if err != nil || urlID < 0 || urlID >= len(snapshot.tagJSON) {
		c.JSON(http.StatusUnprocessableEntity, MessageResponse{Data: "id must be between 0 and " + strconv.Itoa(len(snapshot.tagJSON)-1)})
		return
	}
	c.Data(http.StatusOK, "application/json; charset=utf-8", snapshot.tagJSON[urlID])
}

// getTagsHandler godoc
// @Summary Count links for all configured URLs
// @Tags tags
// @Produce json
// @Success 200 {object} TagsResponse
// @Failure 503 {object} MessageResponse
// @Router /v1/tags [get]
func (s *Server) getTagsHandler(c *gin.Context) {
	snapshot := s.current.Load()
	if snapshot == nil {
		c.JSON(http.StatusServiceUnavailable, MessageResponse{Data: "cache warming up, retry shortly"})
		return
	}
	c.Data(http.StatusOK, "application/json; charset=utf-8", snapshot.tagsJSON)
}

// clearCacheHandler godoc
// @Summary Force an out-of-band cache refresh
// @Tags system
// @Produce json
// @Success 200 {object} MessageResponse
// @Router /v1/cache/clear [get]
func (s *Server) clearCacheHandler(c *gin.Context) {
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), s.analyzer.config.Timeout+5*time.Second)
		defer cancel()
		s.refresh(ctx)
	}()
	c.JSON(http.StatusOK, MessageResponse{Data: "cache refresh triggered"})
}

func roundDuration(duration time.Duration) float64 {
	return float64(duration.Microseconds()) / 1000000
}

func buildRouter(server *Server) *gin.Engine {
	router := gin.New()
	// No per-request logger: at high RPS its stdout write dominates the hot path.
	router.Use(gin.Recovery())
	router.GET("/", indexHandler)
	router.GET("/healthcheck", healthHandler)
	router.GET("/v1/tags", server.getTagsHandler)
	router.GET("/v1/tags/:url_id", server.getTagHandler)
	router.GET("/v1/cache/clear", server.clearCacheHandler)
	router.GET("/docs", func(c *gin.Context) {
		c.Redirect(http.StatusPermanentRedirect, "/swagger/index.html")
	})
	router.GET("/swagger/*any", ginSwagger.WrapHandler(swaggerFiles.Handler, ginSwagger.URL("/swagger/doc.json")))
	return router
}

func main() {
	gin.SetMode(gin.ReleaseMode)

	config := loadConfig()
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	server := newServer(newAnalyzer(config))

	// Warm the cache once before accepting traffic so the request path never
	// blocks on network I/O.
	bootstrapCtx, cancel := context.WithTimeout(ctx, config.Timeout+5*time.Second)
	server.refresh(bootstrapCtx)
	cancel()

	go server.run(ctx)

	httpServer := &http.Server{
		Addr:              ":" + port,
		Handler:           buildRouter(server),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = httpServer.Shutdown(shutdownCtx)
	}()

	log.Printf("counter-api listening on :%s (refresh every %s, %d URLs)", port, server.interval, len(config.URLs))
	if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
