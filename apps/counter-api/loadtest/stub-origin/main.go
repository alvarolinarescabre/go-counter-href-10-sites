// Command stub-origin is a deterministic stand-in for the 10 real target sites.
// Point counter-api's TARGET_URLS at it during load tests so the benchmark
// measures counter-api, not the public internet (and doesn't hammer third
// parties at 5000 rps x 10 fan-out).
//
//	go run ./loadtest/stub-origin           # listens on :9000
//	PORT=9001 LINKS=500 go run ./loadtest/stub-origin
package main

import (
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
)

func main() {
	port := envOr("PORT", "9000")
	links := envInt("LINKS", 200)
	padKB := envInt("PAD_KB", 0)

	var b strings.Builder
	b.WriteString("<!doctype html><html><body>\n")
	for i := 0; i < links; i++ {
		b.WriteString(`<a href="https://target.example/page/`)
		b.WriteString(strconv.Itoa(i))
		b.WriteString(`">alpha beta gamma</a>`)
		b.WriteString(`<a href="/relative">ignored ignored</a>` + "\n")
	}
	if padKB > 0 {
		b.WriteString("<!-- ")
		b.WriteString(strings.Repeat("x", padKB*1024))
		b.WriteString(" -->")
	}
	b.WriteString("\n</body></html>\n")
	page := []byte(b.String())

	handler := func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write(page)
	}
	http.HandleFunc("/", handler)

	log.Printf("stub-origin on :%s  (%d absolute links, %d words expected, %d bytes)", port, links, links*3, len(page))
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		log.Fatal(err)
	}
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envInt(key string, def int) int {
	if v, err := strconv.Atoi(os.Getenv(key)); err == nil && v >= 0 {
		return v
	}
	return def
}
