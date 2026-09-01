package main

// @title Counter HREF API
// @version 2.0
// @description Counts words inside links with absolute HTTP(S) hrefs.
// @BasePath /
// @schemes http https

import (
	"context"
	"crypto/tls"
	"io"
	"log"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	_ "github.com/alvarolinarescabre/go-counter-href-10-sites/apps/counter-api/docs"
	"github.com/gin-gonic/gin"
	swaggerFiles "github.com/swaggo/files"
	ginSwagger "github.com/swaggo/gin-swagger"
)

var hrefPattern = regexp.MustCompile(`(?is)<a\s+[^>]*href\s*=\s*["']https?://[^"']*["'][^>]*>(.*?)</a>`)

type Config struct {
	URLs    []string
	Timeout time.Duration
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
		urls = []string{"https://go.dev", "https://www.python.org", "https://www.realpython.com", "https://nodejs.org", "https://www.abc.es", "https://www.gitlab.com", "https://www.youtube.com", "https://www.mozilla.org", "https://www.github.com", "https://www.google.com"}
	}
	for index := range urls {
		urls[index] = strings.TrimSpace(urls[index])
	}
	timeoutSeconds := 10
	if value, err := strconv.Atoi(os.Getenv("HTTP_TIMEOUT_SECONDS")); err == nil && value > 0 {
		timeoutSeconds = value
	}
	return Config{URLs: urls, Timeout: time.Duration(timeoutSeconds) * time.Second}
}

func newAnalyzer(config Config) *Analyzer {
	return &Analyzer{config: config, client: &http.Client{Timeout: config.Timeout, Transport: &http.Transport{TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12}}}}
}

func (a *Analyzer) countURL(ctx context.Context, url string) int {
	var body []byte
	for attempt := 0; attempt < 3; attempt++ {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err == nil {
			req.Header.Set("User-Agent", "Mozilla/5.0 (compatible; CounterAPI/2.0)")
			req.Header.Set("Accept", "text/html,application/xhtml+xml")
			response, requestErr := a.client.Do(req)
			if requestErr == nil {
				body, err = io.ReadAll(response.Body)
				response.Body.Close()
				if err == nil && response.StatusCode < http.StatusBadRequest {
					break
				}
			}
		}
		if attempt < 2 {
			select {
			case <-ctx.Done():
				return 0
			case <-time.After(time.Duration(1<<attempt) * 100 * time.Millisecond):
			}
		}
	}
	count := 0
	for _, match := range hrefPattern.FindAllSubmatch(body, -1) {
		count += len(strings.Fields(string(match[1])))
	}
	return count
}

func (a *Analyzer) analyze(ctx context.Context, urlID int) TagResult {
	url := a.config.URLs[urlID]
	return TagResult{URLID: urlID, URL: url, Count: a.countURL(ctx, url)}
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
// @Router /v1/tags/{url_id} [get]
func getTagHandler(analyzer *Analyzer) gin.HandlerFunc {
	return func(c *gin.Context) {
		urlID, err := strconv.Atoi(c.Param("url_id"))
		if err != nil || urlID < 0 || urlID >= len(analyzer.config.URLs) {
			c.JSON(http.StatusUnprocessableEntity, MessageResponse{Data: "id must be between 0 and 9"})
			return
		}
		started := time.Now()
		result := analyzer.analyze(c.Request.Context(), urlID)
		result.Time = roundDuration(time.Since(started))
		c.JSON(http.StatusOK, result)
	}
}

// getTagsHandler godoc
// @Summary Count links for all configured URLs
// @Tags tags
// @Produce json
// @Success 200 {object} TagsResponse
// @Router /v1/tags [get]
func getTagsHandler(analyzer *Analyzer) gin.HandlerFunc {
	return func(c *gin.Context) {
		started := time.Now()
		results := analyzer.analyzeAll(c.Request.Context())
		c.JSON(http.StatusOK, TagsResponse{Data: results, TotalTime: roundDuration(time.Since(started)), URLsProcessed: len(results)})
	}
}

// clearCacheHandler godoc
// @Summary Clear in-memory cache
// @Tags system
// @Produce json
// @Success 200 {object} MessageResponse
// @Router /v1/cache/clear [get]
func clearCacheHandler(c *gin.Context) {
	c.JSON(http.StatusOK, MessageResponse{Data: "Cache has been cleared successfully"})
}

func roundDuration(duration time.Duration) float64 {
	return float64(duration.Microseconds()) / 1000000
}

func main() {
	config := loadConfig()
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	analyzer := newAnalyzer(config)
	router := gin.New()
	router.Use(gin.Logger(), gin.Recovery())
	router.GET("/", indexHandler)
	router.GET("/healthcheck", healthHandler)
	router.GET("/v1/tags", getTagsHandler(analyzer))
	router.GET("/v1/tags/:url_id", getTagHandler(analyzer))
	router.GET("/v1/cache/clear", clearCacheHandler)
	router.GET("/docs", func(c *gin.Context) {
		c.Redirect(http.StatusPermanentRedirect, "/swagger/index.html")
	})
	router.GET("/swagger/*any", ginSwagger.WrapHandler(swaggerFiles.Handler, ginSwagger.URL("/swagger/doc.json")))
	log.Printf("counter-api listening on :%s", port)
	if err := router.Run(":" + port); err != nil {
		log.Fatal(err)
	}
}
