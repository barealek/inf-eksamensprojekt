package main

import (
	"context"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/barealek/inf-eksamensprojekt/api"
	"github.com/barealek/inf-eksamensprojekt/database"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	db, err := database.Connect(ctx)
	if err != nil {
		log.Fatalf("database: %v", err)
	}
	defer db.Close()

	mux := http.NewServeMux()
	apiMux := http.NewServeMux()
	api.Register(apiMux, db)
	mux.Handle("/api/", http.StripPrefix("/api", apiMux))

	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	// Cannot use "GET /" here: it conflicts with "/api/" (method-specific vs subtree). Use "/" and
	// restrict to GET; /api/* is handled by "/api/". SPA: unknown paths → index.html.
	staticRoot := "./static"
	mux.Handle("/", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		serveStaticSPA(w, r, staticRoot)
	}))

	srv := &http.Server{
		Addr:              ":8080",
		Handler:           withCORS(mux),
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
	}()

	// Dagligt ryd op i gamle lærer sessions
	go func() {
		for {
			now := time.Now()
			next := time.Date(now.Year(), now.Month(), now.Day()+1, 0, 0, 0, 0, time.Local)
			time.Sleep(time.Until(next))
			if err := db.DeleteOldTeacherSessions(context.Background()); err != nil {
				log.Printf("session cleanup: %v", err)
			}
		}
	}()

	log.Printf("listening on %s", srv.Addr)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}

// serveStaticSPA serves files from root; missing files (client routes like /queues) get index.html.
func serveStaticSPA(w http.ResponseWriter, r *http.Request, root string) {
	p := path.Clean(r.URL.Path)
	if p == "." || p == "/" {
		http.ServeFile(w, r, filepath.Join(root, "index.html"))
		return
	}
	if !strings.HasPrefix(p, "/") {
		p = "/" + p
	}
	local := filepath.Join(root, strings.TrimPrefix(p, "/"))
	if !filePathUnderRoot(root, local) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	fi, err := os.Stat(local)
	if err == nil && !fi.IsDir() {
		http.ServeFile(w, r, local)
		return
	}
	if err == nil && fi.IsDir() {
		idx := filepath.Join(local, "index.html")
		if _, err := os.Stat(idx); err == nil {
			http.ServeFile(w, r, idx)
			return
		}
	}
	http.ServeFile(w, r, filepath.Join(root, "index.html"))
}

func filePathUnderRoot(root, full string) bool {
	absRoot, err1 := filepath.Abs(root)
	absFull, err2 := filepath.Abs(full)
	if err1 != nil || err2 != nil {
		return false
	}
	sep := string(os.PathSeparator)
	return absFull == absRoot || strings.HasPrefix(absFull, absRoot+sep)
}

// withCORS allows browser credentialed requests from Vite (or CORS_ORIGINS).
func withCORS(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		if corsAllowed(origin) {
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Set("Access-Control-Allow-Credentials", "true")
		}
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func corsAllowed(origin string) bool {
	if origin == "" {
		return false
	}
	if custom := strings.TrimSpace(os.Getenv("CORS_ORIGINS")); custom != "" {
		for _, o := range strings.Split(custom, ",") {
			if strings.TrimSpace(o) == origin {
				return true
			}
		}
		return false
	}
	u, err := url.Parse(origin)
	if err != nil {
		return false
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return false
	}
	h := u.Hostname()
	return h == "localhost" || h == "127.0.0.1" || h == "::1"
}
