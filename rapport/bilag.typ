= Bilag

#image("billeder/arkitektur.png", width: 66%)
_Bilag 1: Applikationens overordnede arkitektur_
#v(2em)

#image("billeder/er-skema.png", width: 66%)
_Bilag 2: Entity-relationship diagram over databasen_
#v(2em)

#image("billeder/validering-flow.png", width: 66%)
_Bilag 3: Visualisering over, hvordan serveren validerer brugere_
#v(2em)

#image("billeder/hashing-flow.png", width: 66%)
_Bilag 4: Visualisering over, hvordan serveren hasher brugeres koder_
#v(2em)

#image("billeder/skitse-af-lærerside.jpg", width: 66%)
_Bilag 5: Skitse af lærersiden_
#v(2em)

#image("billeder/layout-lærer.png", width: 66%)
_Bilag 6: Screenshot af lærersiden_
#v(2em)

#image("billeder/layout-elev.jpg", width: 40%)
_Bilag 7: Screenshot af elevsiden_

== API-kode

`main.go`
```go
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
```

`api/api.go`
```go
package api

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/barealek/inf-eksamensprojekt/database"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgconn"
	"golang.org/x/crypto/bcrypt"
)

const (
	cookieTeacherSession = "teacher_session"
	cookieStudentEntry   = "student_entry"
	cookieStudentSecret  = "student_secret"
)

// Register attaches auth and queue routes to mux (Go 1.22+ patterns).
func Register(mux *http.ServeMux, db *database.DB) {
	mux.HandleFunc("POST /auth/register", postAuthRegister(db))
	mux.HandleFunc("POST /auth/login", postAuthLogin(db))
	mux.HandleFunc("GET /queues", getQueuesList(db))
	mux.HandleFunc("POST /queues/new", postQueuesNew(db))
	mux.HandleFunc("GET /queues/{id}/me", getQueueMe(db))
	mux.HandleFunc("PATCH /queues/{id}/note", patchQueueNote(db))
	mux.HandleFunc("POST /queues/{id}/student/dismiss", postStudentDismiss(db))
	mux.HandleFunc("GET /queues/{id}", getQueue(db))
	mux.HandleFunc("POST /queues/{id}/join", postQueueJoin(db))
	mux.HandleFunc("POST /queues/{id}/mark-helped", postMarkHelped(db))
}

func postAuthRegister(db *database.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Username string `json:"username"`
			Password string `json:"password"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, "invalid json", http.StatusBadRequest)
			return
		}
		u := normalizeUsername(body.Username)
		if err := validateTeacherCredentials(u, body.Password); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		hash, err := bcrypt.GenerateFromPassword([]byte(body.Password), bcrypt.DefaultCost)
		if err != nil {
			log.Printf("bcrypt: %v", err)
			http.Error(w, "server error", http.StatusInternalServerError)
			return
		}
		_, err = db.CreateTeacher(r.Context(), u, string(hash))
		if err != nil {
			var pgErr *pgconn.PgError
			if errors.As(err, &pgErr) && pgErr.Code == "23505" {
				http.Error(w, "username taken", http.StatusConflict)
				return
			}
			log.Printf("CreateTeacher: %v", err)
			http.Error(w, "server error", http.StatusInternalServerError)
			return
		}
		writeJSON(w, http.StatusCreated, map[string]string{"status": "ok"})
	}
}

func postAuthLogin(db *database.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Username string `json:"username"`
			Password string `json:"password"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, "invalid json", http.StatusBadRequest)
			return
		}
		u := normalizeUsername(body.Username)
		if u == "" || body.Password == "" {
			http.Error(w, "invalid credentials", http.StatusUnauthorized)
			return
		}
		t, err := db.TeacherByUsername(r.Context(), u)
		if err != nil {
			log.Printf("TeacherByUsername: %v", err)
			http.Error(w, "server error", http.StatusInternalServerError)
			return
		}
		if t == nil || bcrypt.CompareHashAndPassword([]byte(t.PasswordHash), []byte(body.Password)) != nil {
			http.Error(w, "invalid credentials", http.StatusUnauthorized)
			return
		}
		if err := db.TouchTeacherLogin(r.Context(), t.ID); err != nil {
			log.Printf("TouchTeacherLogin: %v", err)
			http.Error(w, "server error", http.StatusInternalServerError)
			return
		}
		token, err := randomHex(32)
		if err != nil {
			http.Error(w, "server error", http.StatusInternalServerError)
			return
		}
		s, err := db.CreateTeacherSession(r.Context(), t.ID, token)
		if err != nil {
			log.Printf("CreateTeacherSession: %v", err)
			http.Error(w, "server error", http.StatusInternalServerError)
			return
		}
		setCookie(w, cookieTeacherSession, s.Token, sessionCookieOpts())
		writeJSON(w, http.StatusOK, map[string]string{
			"status":   "ok",
			"username": t.Username,
		})
	}
}

func normalizeUsername(s string) string {
	return strings.ToLower(strings.TrimSpace(s))
}

func validateTeacherCredentials(username, password string) error {
	if utf8.RuneCountInString(username) < 3 {
		return errors.New("username must be at least 3 characters")
	}
	if utf8.RuneCountInString(username) > 64 {
		return errors.New("username must be at most 64 characters")
	}
	if strings.ContainsAny(username, " \t\n\r") {
		return errors.New("username must not contain whitespace")
	}
	if len(password) < 8 {
		return errors.New("password must be at least 8 characters")
	}
	return nil
}

func getQueuesList(db *database.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ts, ok := teacherFromRequest(db, r)
		if !ok {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		list, err := db.ListQueuesForSession(r.Context(), ts.ID)
		if err != nil {
			log.Printf("ListQueuesForSession: %v", err)
			http.Error(w, "server error", http.StatusInternalServerError)
			return
		}
		type row struct {
			ID        string `json:"id"`
			CreatedAt string `json:"created_at"`
			Waiting   int    `json:"waiting"`
		}
		out := make([]row, 0, len(list))
		for _, q := range list {
			out = append(out, row{
				ID:        q.ID.String(),
				CreatedAt: q.CreatedAt.UTC().Format(time.RFC3339),
				Waiting:   q.Waiting,
			})
		}
		writeJSON(w, http.StatusOK, map[string]any{"queues": out})
	}
}

func getQueueMe(db *database.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		idStr := r.PathValue("id")
		qid, err := uuid.Parse(idStr)
		if err != nil {
			http.Error(w, "invalid queue id", http.StatusBadRequest)
			return
		}
		q, err := db.QueueByID(r.Context(), qid)
		if err != nil {
			log.Printf("QueueByID: %v", err)
			http.Error(w, "server error", http.StatusInternalServerError)
			return
		}
		if q == nil {
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
		eid, ok, err := StudentFromRequest(r.Context(), db, r)
		if err != nil {
			if errors.Is(err, ErrInvalidStudentCookie) {
				clearStudentCookies(w)
				writeJSON(w, http.StatusUnauthorized, map[string]any{"authenticated": false})
				return
			}
			log.Printf("StudentFromRequest: %v", err)
			http.Error(w, "server error", http.StatusInternalServerError)
			return
		}
		if !ok {
			writeJSON(w, http.StatusOK, map[string]any{"authenticated": false})
			return
		}
		entry, err := db.QueueEntryByID(r.Context(), eid)
		if err != nil {
			log.Printf("QueueEntryByID: %v", err)
			http.Error(w, "server error", http.StatusInternalServerError)
			return
		}
		if entry == nil || entry.QueueID != qid {
			writeJSON(w, http.StatusOK, map[string]any{"authenticated": false})
			return
		}
		total, err := db.CountWaitingInQueue(r.Context(), qid)
		if err != nil {
			log.Printf("CountWaitingInQueue: %v", err)
			http.Error(w, "server error", http.StatusInternalServerError)
			return
		}
		if entry.HelpedAt != nil {
			writeJSON(w, http.StatusOK, map[string]any{
				"authenticated": true,
				"display_name":  entry.DisplayName,
				"note":          entry.Note,
				"helped":        true,
				"position":      nil,
				"waiting_ahead": 0,
				"total_waiting": total,
			})
			return
		}
		ahead, err := db.WaitingAheadCount(r.Context(), qid, entry.ID, entry.CreatedAt)
		if err != nil {
			log.Printf("WaitingAheadCount: %v", err)
			http.Error(w, "server error", http.StatusInternalServerError)
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"authenticated": true,
			"display_name":  entry.DisplayName,
			"note":          entry.Note,
			"helped":        false,
			"position":      ahead + 1,
			"waiting_ahead": ahead,
			"total_waiting": total,
		})
	}
}

func patchQueueNote(db *database.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		idStr := r.PathValue("id")
		qid, err := uuid.Parse(idStr)
		if err != nil {
			http.Error(w, "invalid queue id", http.StatusBadRequest)
			return
		}
		eid, ok, err := StudentFromRequest(r.Context(), db, r)
		if err != nil {
			if errors.Is(err, ErrInvalidStudentCookie) {
				clearStudentCookies(w)
				writeJSON(w, http.StatusUnauthorized, map[string]string{"status": "cleared"})
				return
			}
			log.Printf("StudentFromRequest: %v", err)
			http.Error(w, "server error", http.StatusInternalServerError)
			return
		}
		if !ok {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		entry, err := db.QueueEntryByID(r.Context(), eid)
		if err != nil {
			log.Printf("QueueEntryByID: %v", err)
			http.Error(w, "server error", http.StatusInternalServerError)
			return
		}
		if entry.QueueID != qid {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		var body = struct {
			Note string `json:"note"`
		}{}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, "invalid request", http.StatusBadRequest)
			return
		}
		if _, err := db.UpdateQueueEntryNote(r.Context(), entry.ID, body.Note); err != nil {
			log.Printf("UpdateQueueEntry: %v", err)
			http.Error(w, "server error", http.StatusInternalServerError)
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	}
}

func postStudentDismiss(db *database.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		idStr := r.PathValue("id")
		qid, err := uuid.Parse(idStr)
		if err != nil {
			http.Error(w, "invalid queue id", http.StatusBadRequest)
			return
		}
		eid, ok, err := StudentFromRequest(r.Context(), db, r)
		if err != nil {
			if errors.Is(err, ErrInvalidStudentCookie) {
				clearStudentCookies(w)
				writeJSON(w, http.StatusUnauthorized, map[string]string{"status": "cleared"})
				return
			}
			log.Printf("StudentFromRequest: %v", err)
			http.Error(w, "server error", http.StatusInternalServerError)
			return
		}
		if !ok {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		entry, err := db.QueueEntryByID(r.Context(), eid)
		if err != nil {
			log.Printf("QueueEntryByID: %v", err)
			http.Error(w, "server error", http.StatusInternalServerError)
			return
		}
		if entry == nil || entry.QueueID != qid {
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
		if entry.HelpedAt == nil {
			http.Error(w, "not helped yet", http.StatusConflict)
			return
		}
		clearStudentCookies(w)
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	}
}

func clearStudentCookies(w http.ResponseWriter) {
	expire := cookieOptions{
		Path:     "/",
		MaxAge:   -1,
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		Secure:   os.Getenv("COOKIE_SECURE") == "1",
	}
	setCookie(w, cookieStudentEntry, "", expire)
	setCookie(w, cookieStudentSecret, "", expire)
}

func postQueuesNew(db *database.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ts, ok := teacherFromRequest(db, r)
		if !ok {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		q, err := db.CreateQueue(r.Context(), ts.ID)
		if err != nil {
			log.Printf("CreateQueue: %v", err)
			http.Error(w, "server error", http.StatusInternalServerError)
			return
		}
		writeJSON(w, http.StatusCreated, map[string]string{"id": q.ID.String()})
	}
}

func getQueue(db *database.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		idStr := r.PathValue("id")
		qid, err := uuid.Parse(idStr)
		if err != nil {
			http.Error(w, "invalid queue id", http.StatusBadRequest)
			return
		}
		q, err := db.QueueByID(r.Context(), qid)
		if err != nil {
			log.Printf("QueueByID: %v", err)
			http.Error(w, "server error", http.StatusInternalServerError)
			return
		}
		if q == nil {
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
		entries, err := db.ListQueueEntries(r.Context(), qid)
		if err != nil {
			log.Printf("ListQueueEntries: %v", err)
			http.Error(w, "server error", http.StatusInternalServerError)
			return
		}
		type row struct {
			ID          string  `json:"id"`
			DisplayName string  `json:"display_name"`
			Note        *string `json:"note"`
			CreatedAt   string  `json:"created_at"`
			HelpedAt    *string `json:"helped_at"`
		}
		out := make([]row, 0, len(entries))
		for _, e := range entries {
			var helped *string
			if e.HelpedAt != nil {
				s := e.HelpedAt.UTC().Format(time.RFC3339)
				helped = &s
			}
			out = append(out, row{
				ID:          e.ID.String(),
				DisplayName: e.DisplayName,
				Note:        e.Note,
				CreatedAt:   e.CreatedAt.UTC().Format(time.RFC3339),
				HelpedAt:    helped,
			})
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"id":         q.ID.String(),
			"created_at": q.CreatedAt.UTC().Format(time.RFC3339),
			"entries":    out,
		})
	}
}

func postQueueJoin(db *database.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		idStr := r.PathValue("id")
		qid, err := uuid.Parse(idStr)
		if err != nil {
			http.Error(w, "invalid queue id", http.StatusBadRequest)
			return
		}
		q, err := db.QueueByID(r.Context(), qid)
		if err != nil {
			log.Printf("QueueByID: %v", err)
			http.Error(w, "server error", http.StatusInternalServerError)
			return
		}
		if q == nil {
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
		var body struct {
			Name string `json:"name"`
			Note string `json:"note"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, "invalid json", http.StatusBadRequest)
			return
		}
		body.Name = strings.TrimSpace(body.Name)
		if body.Name == "" {
			http.Error(w, "name required", http.StatusBadRequest)
			return
		}
		secret, err := randomHex(24)
		if err != nil {
			http.Error(w, "server error", http.StatusInternalServerError)
			return
		}
		var note = new(string)
		if body.Note != "" {
			*note = strings.TrimSpace(body.Note)
		}
		entry, err := db.AddQueueEntry(r.Context(), qid, body.Name, note, secret)
		if err != nil {
			log.Printf("AddQueueEntry: %v", err)
			http.Error(w, "server error", http.StatusInternalServerError)
			return
		}
		setCookie(w, cookieStudentEntry, entry.ID.String(), studentCookieOpts())
		setCookie(w, cookieStudentSecret, secret, studentCookieOpts())
		writeJSON(w, http.StatusCreated, map[string]string{
			"entry_id": entry.ID.String(),
		})
	}
}

func postMarkHelped(db *database.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ts, ok := teacherFromRequest(db, r)
		if !ok {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		idStr := r.PathValue("id")
		qid, err := uuid.Parse(idStr)
		if err != nil {
			http.Error(w, "invalid queue id", http.StatusBadRequest)
			return
		}
		owned, err := db.QueueOwnedBy(r.Context(), qid, ts.ID)
		if err != nil {
			log.Printf("QueueOwnedBy: %v", err)
			http.Error(w, "server error", http.StatusInternalServerError)
			return
		}
		if !owned {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		var body struct {
			EntryID string `json:"entry_id"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, "invalid json", http.StatusBadRequest)
			return
		}
		eid, err := uuid.Parse(strings.TrimSpace(body.EntryID))
		if err != nil {
			http.Error(w, "invalid entry id", http.StatusBadRequest)
			return
		}
		updated, err := db.MarkEntryHelped(r.Context(), qid, eid)
		if err != nil {
			log.Printf("MarkEntryHelped: %v", err)
			http.Error(w, "server error", http.StatusInternalServerError)
			return
		}
		if !updated {
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	}
}

func teacherFromRequest(db *database.DB, r *http.Request) (*database.TeacherSession, bool) {
	c, err := r.Cookie(cookieTeacherSession)
	if err != nil || c.Value == "" {
		return nil, false
	}
	s, err := db.TeacherSessionByToken(r.Context(), c.Value)
	if err != nil {
		log.Printf("TeacherSessionByToken: %v", err)
		return nil, false
	}
	if s == nil {
		return nil, false
	}
	return s, true
}

func randomHex(byteLen int) (string, error) {
	b := make([]byte, byteLen)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

func sessionCookieOpts() cookieOptions {
	return cookieOptions{
		Path:     "/",
		MaxAge:   int((7 * 24 * time.Hour).Seconds()),
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		Secure:   os.Getenv("COOKIE_SECURE") == "1",
	}
}

func studentCookieOpts() cookieOptions {
	return sessionCookieOpts()
}

type cookieOptions struct {
	Path     string
	MaxAge   int
	HttpOnly bool
	SameSite http.SameSite
	Secure   bool
}

func setCookie(w http.ResponseWriter, name, value string, o cookieOptions) {
	http.SetCookie(w, &http.Cookie{
		Name:     name,
		Value:    value,
		Path:     o.Path,
		MaxAge:   o.MaxAge,
		HttpOnly: o.HttpOnly,
		SameSite: o.SameSite,
		Secure:   o.Secure,
	})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// AuthAPI returns a sub-router for /auth prefix (optional legacy mount).
func AuthAPI(db *database.DB) http.Handler {
	m := http.NewServeMux()
	m.HandleFunc("POST /register", postAuthRegister(db))
	m.HandleFunc("POST /login", postAuthLogin(db))
	return m
}

// ErrInvalidStudentCookie is returned when student cookies do not match DB.
var ErrInvalidStudentCookie = errors.New("invalid student session")

// StudentFromRequest loads entry id + secret from cookies and verifies against DB.
func StudentFromRequest(ctx context.Context, db *database.DB, r *http.Request) (entryID uuid.UUID, ok bool, err error) {
	ce, err := r.Cookie(cookieStudentEntry)
	if err != nil || ce.Value == "" {
		return uuid.Nil, false, nil
	}
	cs, err := r.Cookie(cookieStudentSecret)
	if err != nil || cs.Value == "" {
		return uuid.Nil, false, nil
	}
	eid, err := uuid.Parse(ce.Value)
	if err != nil {
		return uuid.Nil, false, nil
	}
	valid, err := db.EntrySecretValid(ctx, eid, cs.Value)
	if err != nil {
		return uuid.Nil, false, err
	}
	if !valid {
		return uuid.Nil, false, ErrInvalidStudentCookie
	}
	return eid, true, nil
}
```

`database/db.go`
```go
package database

import (
	"context"
	"embed"
	"errors"
	"fmt"
	"os"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed schema.sql
var schemaFS embed.FS

// DB wraps a pgx connection pool and queue-related queries.
type DB struct {
	Pool *pgxpool.Pool
}

// Connect opens a pool from DATABASE_URL and runs schema migration.
func Connect(ctx context.Context) (*DB, error) {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		return nil, errors.New("DATABASE_URL is not set")
	}
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("parse dsn: %w", err)
	}
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("connect: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("ping: %w", err)
	}
	db := &DB{Pool: pool}
	if err := db.Migrate(ctx); err != nil {
		pool.Close()
		return nil, err
	}
	return db, nil
}

// Migrate applies schema.sql (idempotent CREATE IF NOT EXISTS).
func (db *DB) Migrate(ctx context.Context) error {
	sqlBytes, err := schemaFS.ReadFile("schema.sql")
	if err != nil {
		return fmt.Errorf("read schema: %w", err)
	}
	if _, err := db.Pool.Exec(ctx, string(sqlBytes)); err != nil {
		return fmt.Errorf("migrate: %w", err)
	}
	return nil
}

// Close releases the pool.
func (db *DB) Close() {
	db.Pool.Close()
}

// Teacher is a registered lærer-konto.
type Teacher struct {
	ID           uuid.UUID
	Username     string
	PasswordHash string
	CreatedAt    time.Time
	LastLoginAt  *time.Time
}

// TeacherByUsername loads a teacher for login (includes password hash).
func (db *DB) TeacherByUsername(ctx context.Context, username string) (*Teacher, error) {
	var t Teacher
	var last pgtype.Timestamptz
	err := db.Pool.QueryRow(ctx,
		`SELECT id, username, password_hash, created_at, last_login_at
		 FROM teachers WHERE LOWER(username) = LOWER($1)`,
		username,
	).Scan(&t.ID, &t.Username, &t.PasswordHash, &t.CreatedAt, &last)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if last.Valid {
		ts := last.Time
		t.LastLoginAt = &ts
	}
	return &t, nil
}

// CreateTeacher inserts a new teacher account.
func (db *DB) CreateTeacher(ctx context.Context, username, passwordHash string) (*Teacher, error) {
	id := uuid.New()
	var t Teacher
	var last pgtype.Timestamptz
	err := db.Pool.QueryRow(ctx,
		`INSERT INTO teachers (id, username, password_hash)
		 VALUES ($1, $2, $3)
		 RETURNING id, username, password_hash, created_at, last_login_at`,
		id, username, passwordHash,
	).Scan(&t.ID, &t.Username, &t.PasswordHash, &t.CreatedAt, &last)
	if err != nil {
		return nil, err
	}
	if last.Valid {
		ts := last.Time
		t.LastLoginAt = &ts
	}
	return &t, nil
}

// TouchTeacherLogin sets last_login_at to now().
func (db *DB) TouchTeacherLogin(ctx context.Context, teacherID uuid.UUID) error {
	_, err := db.Pool.Exec(ctx,
		`UPDATE teachers SET last_login_at = now() WHERE id = $1`,
		teacherID,
	)
	return err
}

// TeacherSession represents a logged-in teacher cookie session (bound to an account).
type TeacherSession struct {
	ID        uuid.UUID
	TeacherID uuid.UUID
	Token     string
	CreatedAt time.Time
}

// DeleteOldTeacherSessions removes teacher sessions older than 72 hours.
func (db *DB) DeleteOldTeacherSessions(ctx context.Context) error {
	_, err := db.Pool.Exec(ctx,
		`DELETE FROM teacher_sessions WHERE created_at < NOW() - INTERVAL '72 hours'`,
	)
	return err
}

// CreateTeacherSession inserts a new session for a teacher.
func (db *DB) CreateTeacherSession(ctx context.Context, teacherID uuid.UUID, token string) (*TeacherSession, error) {
	id := uuid.New()
	var s TeacherSession
	err := db.Pool.QueryRow(ctx,
		`INSERT INTO teacher_sessions (id, teacher_id, token) VALUES ($1, $2, $3)
		 RETURNING id, teacher_id, token, created_at`,
		id, teacherID, token,
	).Scan(&s.ID, &s.TeacherID, &s.Token, &s.CreatedAt)
	if err != nil {
		return nil, err
	}
	return &s, nil
}

// TeacherSessionByToken returns the session if the token is valid and bound to a teacher.
func (db *DB) TeacherSessionByToken(ctx context.Context, token string) (*TeacherSession, error) {
	var s TeacherSession
	var tid pgtype.UUID
	err := db.Pool.QueryRow(ctx,
		`SELECT id, teacher_id, token, created_at FROM teacher_sessions WHERE token = $1`,
		token,
	).Scan(&s.ID, &tid, &s.Token, &s.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if !tid.Valid {
		return nil, nil
	}
	s.TeacherID = uuid.UUID(tid.Bytes)
	return &s, nil
}

// Queue is a vejledningskø owned by a teacher session.
type Queue struct {
	ID               uuid.UUID
	TeacherSessionID uuid.UUID
	CreatedAt        time.Time
}

// CreateQueue creates a queue for the given teacher session.
func (db *DB) CreateQueue(ctx context.Context, teacherSessionID uuid.UUID) (*Queue, error) {
	id := uuid.New()
	var q Queue
	err := db.Pool.QueryRow(ctx,
		`INSERT INTO queues (id, teacher_session_id) VALUES ($1, $2)
		 RETURNING id, teacher_session_id, created_at`,
		id, teacherSessionID,
	).Scan(&q.ID, &q.TeacherSessionID, &q.CreatedAt)
	if err != nil {
		return nil, err
	}
	return &q, nil
}

// QueueByID loads a queue by id.
func (db *DB) QueueByID(ctx context.Context, id uuid.UUID) (*Queue, error) {
	var q Queue
	err := db.Pool.QueryRow(ctx,
		`SELECT id, teacher_session_id, created_at FROM queues WHERE id = $1`,
		id,
	).Scan(&q.ID, &q.TeacherSessionID, &q.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &q, nil
}

// QueueOwnedBy returns whether the queue belongs to the teacher session.
func (db *DB) QueueOwnedBy(ctx context.Context, queueID, teacherSessionID uuid.UUID) (bool, error) {
	var n int
	err := db.Pool.QueryRow(ctx,
		`SELECT 1 FROM queues WHERE id = $1 AND teacher_session_id = $2`,
		queueID, teacherSessionID,
	).Scan(&n)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, nil
}

// QueueEntry is one student in a queue (student_secret matches cookie).
type QueueEntry struct {
	ID          uuid.UUID
	QueueID     uuid.UUID
	DisplayName string
	Note        *string
	CreatedAt   time.Time
	HelpedAt    *time.Time
}

// AddQueueEntry appends a student; studentSecret is stored for later cookie checks.
func (db *DB) AddQueueEntry(ctx context.Context, queueID uuid.UUID, displayName string, note *string, studentSecret string) (*QueueEntry, error) {
	id := uuid.New()
	var e QueueEntry
	err := db.Pool.QueryRow(ctx,
		`INSERT INTO queue_entries (id, queue_id, display_name, note, student_secret)
		 VALUES ($1, $2, $3, $4, $5)
		 RETURNING id, queue_id, display_name, note, created_at`,
		id, queueID, displayName, note, studentSecret,
	).Scan(&e.ID, &e.QueueID, &e.DisplayName, &e.Note, &e.CreatedAt)
	if err != nil {
		return nil, err
	}
	return &e, nil
}

// ListQueueEntries returns entries for a queue (no secrets). Waiting first, then helped.
func (db *DB) ListQueueEntries(ctx context.Context, queueID uuid.UUID) ([]QueueEntry, error) {
	rows, err := db.Pool.Query(ctx,
		`SELECT id, queue_id, display_name, note, created_at, helped_at
		 FROM queue_entries WHERE queue_id = $1
		 ORDER BY (helped_at IS NULL) DESC, created_at ASC`,
		queueID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []QueueEntry
	for rows.Next() {
		var e QueueEntry
		var helped pgtype.Timestamptz
		if err := rows.Scan(&e.ID, &e.QueueID, &e.DisplayName, &e.Note, &e.CreatedAt, &helped); err != nil {
			return nil, err
		}
		if helped.Valid {
			ts := helped.Time
			e.HelpedAt = &ts
		}
		list = append(list, e)
	}
	return list, rows.Err()
}

// MarkEntryHelped sets helped_at for an entry in the given queue (idempotent if already helped).
func (db *DB) MarkEntryHelped(ctx context.Context, queueID, entryID uuid.UUID) (ok bool, err error) {
	var id uuid.UUID
	err = db.Pool.QueryRow(ctx,
		`UPDATE queue_entries SET helped_at = COALESCE(helped_at, now())
		 WHERE id = $1 AND queue_id = $2
		 RETURNING id`,
		entryID, queueID,
	).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, nil
}

func (db *DB) UpdateQueueEntryNote(ctx context.Context, entryID uuid.UUID, note string) (ok bool, err error) {
	var id uuid.UUID
	err = db.Pool.QueryRow(ctx,
		`UPDATE queue_entries SET note = $1
		 WHERE id = $2
		 RETURNING id`,
		note, entryID,
	).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, nil
}

// QueueSummary is a queue row with a waiting count for teacher dashboards.
type QueueSummary struct {
	ID        uuid.UUID
	CreatedAt time.Time
	Waiting   int
}

// ListQueuesForSession returns queues owned by the teacher session, newest first.
func (db *DB) ListQueuesForSession(ctx context.Context, sessionID uuid.UUID) ([]QueueSummary, error) {
	rows, err := db.Pool.Query(ctx,
		`SELECT q.id, q.created_at,
			(SELECT COUNT(*)::int FROM queue_entries e WHERE e.queue_id = q.id AND e.helped_at IS NULL)
		 FROM queues q
		 WHERE q.teacher_session_id = $1
		 ORDER BY q.created_at DESC`,
		sessionID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []QueueSummary
	for rows.Next() {
		var s QueueSummary
		if err := rows.Scan(&s.ID, &s.CreatedAt, &s.Waiting); err != nil {
			return nil, err
		}
		list = append(list, s)
	}
	return list, rows.Err()
}

// QueueEntryByID loads one entry (any queue).
func (db *DB) QueueEntryByID(ctx context.Context, entryID uuid.UUID) (*QueueEntry, error) {
	var e QueueEntry
	var helped pgtype.Timestamptz
	err := db.Pool.QueryRow(ctx,
		`SELECT id, queue_id, display_name, note, created_at, helped_at
		 FROM queue_entries WHERE id = $1`,
		entryID,
	).Scan(&e.ID, &e.QueueID, &e.DisplayName, &e.Note, &e.CreatedAt, &helped)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if helped.Valid {
		ts := helped.Time
		e.HelpedAt = &ts
	}
	return &e, nil
}

// WaitingAheadCount returns how many still-waiting entries are strictly before this one in line (FIFO).
func (db *DB) WaitingAheadCount(ctx context.Context, queueID, entryID uuid.UUID, createdAt time.Time) (int, error) {
	var n int
	err := db.Pool.QueryRow(ctx,
		`SELECT COUNT(*)::int FROM queue_entries
		 WHERE queue_id = $1 AND helped_at IS NULL
		   AND (created_at < $2 OR (created_at = $2 AND id < $3))`,
		queueID, createdAt, entryID,
	).Scan(&n)
	if err != nil {
		return 0, err
	}
	return n, nil
}

// CountWaitingInQueue returns the number of entries not yet helped.
func (db *DB) CountWaitingInQueue(ctx context.Context, queueID uuid.UUID) (int, error) {
	var n int
	err := db.Pool.QueryRow(ctx,
		`SELECT COUNT(*)::int FROM queue_entries WHERE queue_id = $1 AND helped_at IS NULL`,
		queueID,
	).Scan(&n)
	if err != nil {
		return 0, err
	}
	return n, nil
}

// EntrySecretValid checks student cookie against one row.
func (db *DB) EntrySecretValid(ctx context.Context, entryID uuid.UUID, secret string) (bool, error) {
	var got string
	err := db.Pool.QueryRow(ctx,
		`SELECT student_secret FROM queue_entries WHERE id = $1`,
		entryID,
	).Scan(&got)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return got == secret, nil
}
```

`database/schema.sql`
```

CREATE TABLE IF NOT EXISTS teachers (
    id UUID PRIMARY KEY,
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_login_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS teacher_sessions (
    id UUID PRIMARY KEY,
    token TEXT NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    teacher_id UUID REFERENCES teachers (id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_teacher_sessions_teacher_id ON teacher_sessions (teacher_id);

CREATE TABLE IF NOT EXISTS queues (
    id UUID PRIMARY KEY,
    teacher_session_id UUID NOT NULL REFERENCES teacher_sessions (id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_queues_teacher_session ON queues (teacher_session_id);

CREATE TABLE IF NOT EXISTS queue_entries (
    id UUID PRIMARY KEY,
    queue_id UUID NOT NULL REFERENCES queues (id) ON DELETE CASCADE,
    display_name TEXT NOT NULL,
    note TEXT,
    student_secret TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    helped_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_queue_entries_queue_id ON queue_entries (queue_id);
```

== Frontend-kode
`app.jsx`
```js
import { Router, Route } from '@solidjs/router'
import Login from './pages/Login'
import QueueList from './pages/QueueList'
import QueueDetail from './pages/QueueDetail'
import Wait from './pages/Wait'

export default function App() {
  return (
    <div class="app-shell">
      <Router>
        <Route path="/" component={Login} />
        <Route path="/queues" component={QueueList} />
        <Route path="/queue/:id" component={QueueDetail} />
        <Route path="/wait/:id" component={Wait} />
      </Router>
    </div>
  )
}
```

`Login.jsx`
```js
import { createSignal, onMount } from 'solid-js'
import { useNavigate } from '@solidjs/router'
import { login, listQueues } from '../lib/api'

export default function Login() {
  const navigate = useNavigate()
  const [username, setUsername] = createSignal('')
  const [password, setPassword] = createSignal('')
  const [error, setError] = createSignal('')
  const [loading, setLoading] = createSignal(false)
  const [checking, setChecking] = createSignal(true)

  onMount(async () => {
    try {
      await listQueues()
      navigate('/queues', { replace: true })
    } catch (e) {
      if (e.status !== 401) {
        setError('Kunne ikke kontakte serveren. Tjek at API kører.')
      }
    } finally {
      setChecking(false)
    }
  })

  async function onSubmit(e) {
    e.preventDefault()
    setError('')
    setLoading(true)
    try {
      await login(username().trim(), password())
      navigate('/queues', { replace: true })
    } catch (err) {
      setError(err.message || 'Login mislykkedes')
    } finally {
      setLoading(false)
    }
  }

  return (
    <main class="page page--narrow">
      <div class="card">
        <h1 class="app-title">Vejledningskø</h1>
        <p class="lede">Log ind som lærer for at administrere dine køer.</p>
        {checking() ? (
          <p class="muted">Tjekker session…</p>
        ) : (
          <form class="form" onSubmit={onSubmit}>
            <label class="field">
              <span class="field-label">Brugernavn</span>
              <input
                class="input"
                name="username"
                autocomplete="username"
                value={username()}
                onInput={(e) => setUsername(e.currentTarget.value)}
                required
                minLength={3}
              />
            </label>
            <label class="field">
              <span class="field-label">Adgangskode</span>
              <input
                class="input"
                type="password"
                name="password"
                autocomplete="current-password"
                value={password()}
                onInput={(e) => setPassword(e.currentTarget.value)}
                required
                minLength={8}
              />
            </label>
            {error() && <p class="form-error">{error()}</p>}
            <button class="btn btn-primary" type="submit" disabled={loading()}>
              {loading() ? 'Logger ind…' : 'Log ind'}
            </button>
          </form>
        )}
      </div>
    </main>
  )
}
```

`QueueList.jsx`
```js
import {
  createResource,
  Show,
  For,
  createSignal,
  createEffect,
} from "solid-js";
import { A, useNavigate } from "@solidjs/router";
import { listQueues, createQueue } from "../lib/api";

export default function QueueList() {
  const navigate = useNavigate();
  const [busy, setBusy] = createSignal(false);
  const [err, setErr] = createSignal("");

  const [queues, { refetch }] = createResource(async () => {
    const data = await listQueues();
    return data.queues ?? [];
  });

  createEffect(() => {
    const e = queues.error;
    if (e?.status === 401) {
      navigate("/", { replace: true });
    }
  });

  async function onNewQueue() {
    setErr("");
    setBusy(true);
    try {
      const { id } = await createQueue();
      await refetch();
      navigate(`/queue/${id}`);
    } catch (e) {
      if (e.status === 401) {
        navigate("/", { replace: true });
        return;
      }
      setErr(e.message || "Kunne ikke oprette kø");
    } finally {
      setBusy(false);
    }
  }

  return (
    <main class="page">
      <header class="page-header">
        <div>
          <h1 class="page-title">Dine køer</h1>
          <p class="muted">Åbn en kø for at se deltagere og dele QR-koden.</p>
        </div>
        <button
          class="btn btn-primary"
          type="button"
          onClick={onNewQueue}
          disabled={busy() || queues.loading}
        >
          {busy() ? "Opretter…" : "Ny kø"}
        </button>
      </header>

      <Show when={err()}>
        <p class="banner banner-error">{err()}</p>
      </Show>

      <Show
        when={
          queues.error && queues.error.status !== 401 ? queues.error : false
        }
      >
        {(e) => (
          <p class="banner banner-error">
            {e().message || "Kunne ikke hente køer"}
          </p>
        )}
      </Show>

      <Show when={queues.loading}>
        <p class="muted">Henter køer…</p>
      </Show>

      <Show
        when={!queues.loading && !queues.error && (queues() ?? []).length === 0}
      >
        <div class="card empty-state">
          <p>Du har ingen køer endnu.</p>
          <p class="muted">Opret en ny kø for at komme i gang.</p>
        </div>
      </Show>

      <Show
        when={!queues.loading && !queues.error && (queues() ?? []).length > 0}
      >
        <ul class="queue-grid">
          <For each={queues()}>
            {(q) => (
              <li>
                <A class="queue-card" href={`/queue/${q.id}`}>
                  <span class="queue-card-title">
                    Venteliste fra kl.{" "}
                    {new Date(q.created_at).toLocaleTimeString()}
                  </span>
                  <span class="queue-card-wait">
                    <strong>{q.waiting}</strong>
                    <span class="muted">
                      {q.waiting === 1 ? "person venter" : "personer venter"}
                    </span>
                  </span>
                </A>
              </li>
            )}
          </For>
        </ul>
      </Show>
    </main>
  );
}
```

`QueueDetail.jsx`
```js
import {
  createResource,
  Show,
  createSignal,
  createEffect,
  onCleanup,
} from "solid-js";
import { useParams, A } from "@solidjs/router";
import QRCode from "qrcode";
import { getQueue, markHelped } from "../lib/api";

import TimeAgo from "javascript-time-ago";
import "javascript-time-ago/locale/da";

/** Waiting first (FIFO by joined time), then helped (newest marked done first). */
function sortQueueEntries(entries) {
  return [...(entries ?? [])].sort((a, b) => {
    const aWaiting = !a.helped_at;
    const bWaiting = !b.helped_at;
    if (aWaiting !== bWaiting) return aWaiting ? -1 : 1;
    if (aWaiting) {
      return new Date(a.created_at) - new Date(b.created_at);
    }
    return new Date(b.helped_at) - new Date(a.helped_at);
  });
}

export default function QueueDetail() {
  const params = useParams();
  const queueId = () => params.id;
  const [qrSrc, setQrSrc] = createSignal("");
  const [actionErr, setActionErr] = createSignal("");
  const [pendingId, setPendingId] = createSignal(null);
  /** Bumps once per minute so relative "Fik hjælp …" strings stay current. */
  const [relativeTimeTick, setRelativeTimeTick] = createSignal(0);

  const [data, { refetch }] = createResource(queueId, async (id) => {
    if (!id) return null;
    return getQueue(id);
  });

  createEffect(() => {
    const id = queueId();
    if (!id) return;
    const t = setInterval(() => {
      void refetch();
    }, 5000);
    onCleanup(() => clearInterval(t));
  });

  createEffect(() => {
    const id = queueId();
    if (!id) return;
    const t = setInterval(() => {
      setRelativeTimeTick((n) => n + 1);
    }, 60_000);
    onCleanup(() => clearInterval(t));
  });

  createEffect(() => {
    const id = queueId();
    if (!id) return;
    let cancelled = false;
    onCleanup(() => {
      cancelled = true;
    });
    const url = `${window.location.origin}/wait/${id}`;
    QRCode.toDataURL(url, {
      width: 220,
      margin: 2,
      color: { dark: "#0f172a", light: "#ffffff" },
    })
      .then((src) => {
        if (!cancelled) setQrSrc(src);
      })
      .catch(() => {
        if (!cancelled) setQrSrc("");
      });
  });

  async function handleMark(entryId) {
    setPendingId(entryId);
    setActionErr("");
    try {
      await markHelped(queueId(), entryId);
      await refetch();
    } catch (e) {
      if (e.status === 401) {
        setActionErr(
          "Du skal være logget ind som lærer for at markere færdig.",
        );
      } else {
        setActionErr(e.message || "Kunne ikke markere som færdig");
      }
    } finally {
      setPendingId(null);
    }
  }

  const waitUrl = () =>
    queueId() ? `${window.location.origin}/wait/${queueId()}` : "";

  return (
    <main class="page">
      <nav class="breadcrumb">
        <A href="/queues">← Dine køer</A>
      </nav>

      <Show when={data.state === "pending"}>
        <p class="muted">Henter kø…</p>
      </Show>

      <Show when={data.error}>
        <p class="banner banner-error">
          {data.error.message || "Køen findes ikke"}
        </p>
        <A class="btn btn-secondary" href="/queues">
          Tilbage
        </A>
      </Show>

      <Show when={data()}>
        {(q) => (
          <>
            <header class="page-header page-header--stack">
              <div>
                <h1 class="page-title">
                  Kø fra kl. {new Date(q().created_at).toLocaleTimeString()}
                </h1>
              </div>
            </header>

            <Show when={actionErr()}>
              <p class="banner banner-error">{actionErr()}</p>
            </Show>

            <div class="queue-detail-grid">
              <section class="card">
                <h2 class="section-title">QR</h2>
                <p class="muted small">
                  Scan denne QR-kode for at stille dig i kø
                </p>
                <div class="qr-wrap">
                  <Show
                    when={qrSrc()}
                    fallback={<p class="muted">Genererer QR…</p>}
                  >
                    <img src={qrSrc()} width="220" height="220" alt="" />
                  </Show>
                </div>
              </section>

              <section class="card">
                <h2 class="section-title">I køen</h2>
                <p class="muted small">
                  Tryk på en person når de har fået hjælp.
                </p>
                {(() => {
                  const entries = sortQueueEntries(q().entries);
                  let waitingPlace = 0;
                  return (
                    <>
                      <ul class="entry-list">
                        {entries.map((e) => {
                          const done = !!e.helped_at;
                          const place = done ? null : ++waitingPlace;
                          return (
                            <li>
                              <button
                                type="button"
                                class="entry-row"
                                classList={{
                                  "entry-row--done": done,
                                  "entry-row--pending": pendingId() === e.id,
                                }}
                                disabled={done || pendingId() === e.id}
                                onClick={() => !done && handleMark(e.id)}
                              >
                                <span class="entry-name">
                                  {place != null && (
                                    <>
                                      <small>{place}.</small>{" "}
                                    </>
                                  )}
                                  {e.display_name}
                                  {e.note && <sub> {e.note}</sub>}
                                </span>
                                <span class="entry-meta">
                                  {done
                                    ? (relativeTimeTick(),
                                      "Fik hjælp " +
                                        new TimeAgo("da").format(
                                          new Date(e.helped_at),
                                        ))
                                    : pendingId() === e.id
                                      ? "…"
                                      : "Marker færdig"}
                                </span>
                              </button>
                            </li>
                          );
                        })}
                      </ul>
                      {entries.length === 0 && (
                        <p class="muted">Ingen i køen endnu.</p>
                      )}
                    </>
                  );
                })()}
              </section>
            </div>
          </>
        )}
      </Show>
    </main>
  );
}
```

`Wait.jsx`
```js
import { createSignal, Show, onCleanup, onMount } from "solid-js";
import { useParams } from "@solidjs/router";
import { joinQueue, getQueueMe, dismissStudentSession, updateNote } from "../lib/api";

export default function Wait() {
  const params = useParams();
  const queueId = () => params.id;
  const [name, setName] = createSignal("");
  const [note, setNote] = createSignal("");
  const [err, setErr] = createSignal("");
  const [joining, setJoining] = createSignal(false);
  const [me, setMe] = createSignal(null);
  const [doneMsg, setDoneMsg] = createSignal(false);
  const [boot, setBoot] = createSignal(true);
  const [editingNote, setEditingNote] = createSignal(false);
  const [updatingNote, setUpdatingNote] = createSignal(false);

  let pollTimer;

  async function pollOnce() {
    const id = queueId();
    if (!id) return null;
    try {
      const s = await getQueueMe(id);
      setErr("");
      if (!s.authenticated) {
        setMe(null);
        return s;
      }
      if (s.helped) {
        try {
          await dismissStudentSession(id);
        } catch {
          /* cookies may already be cleared */
        }
        setMe(null);
        setDoneMsg(true);
        stopPoll();
        return s;
      }
      setMe(s);
      return s;
    } catch (e) {
      if (e.status === 401) {
        setMe(null);
        return null;
      }
      setErr(e.message || "Kunne ikke hente status");
      return null;
    }
  }

  function startPoll() {
    stopPoll();
    pollTimer = window.setInterval(() => {
      void pollOnce();
    }, 2500);
  }

  function stopPoll() {
    if (pollTimer) {
      clearInterval(pollTimer);
      pollTimer = undefined;
    }
  }

  onCleanup(stopPoll);

  onMount(async () => {
    const s = await pollOnce();
    setBoot(false);
    if (s?.authenticated && !s.helped) {
      startPoll();
    }
  });

  async function onJoin(e) {
    e.preventDefault();
    setErr("");
    setJoining(true);
    try {
      await joinQueue(queueId(), name().trim(), note());
      const s = await pollOnce();
      if (s?.authenticated && !s.helped) {
        startPoll();
      }
    } catch (e) {
      setErr(e.message || "Kunne ikke melde dig på");
    } finally {
      setJoining(false);
    }
  }

  async function onUpdateNote(e) {
    e.preventDefault();
    setErr("");
    setUpdatingNote(true);
    try {
      await updateNote(queueId(), note());
      setEditingNote(false);
      await pollOnce();
    } catch (e) {
      setErr(e.message || "Kunne ikke opdatere note");
    } finally {
      setUpdatingNote(false);
    }
  }

  return (
    <main class="page page--narrow">
      <div class="card">
        <h1 class="page-title page-title--small">Vejledningskø</h1>
        <p class="muted">Du er ved at stille dig i kø til hjælp.</p>

        <Show when={boot()}>
          <p class="muted">Indlæser…</p>
        </Show>

        <Show when={!boot() && doneMsg()}>
          <p class="banner banner-success">
            Du er blevet markeret som færdig. Tak for i dag.
          </p>
        </Show>

        <Show when={!boot() && !doneMsg() && me()?.authenticated}>
          <div class="wait-status">
            <p class="wait-greeting">Hej, {me()?.display_name}</p>
            <p class="wait-place">
              Du er nummer <strong>{me()?.position}</strong> i køen
            </p>
            <p class="muted small">
              {me()?.waiting_ahead === 0
                ? "Det er din tur snart."
                : `${me()?.waiting_ahead} person${me()?.waiting_ahead === 1 ? "" : "er"} foran dig.`}
            </p>
            <Show when={editingNote()}>
              <form class="form" onSubmit={onUpdateNote}>
                <label class="field">
                  <span class="field-label">Note</span>
                  <input
                    class="input"
                    name="note"
                    placeholder="Fx 'Er ved lokale 1.20'"
                    value={note()}
                    onInput={(ev) => setNote(ev.currentTarget.value)}
                    maxLength={30}
                  />
                </label>
                {err() && <p class="form-error">{err()}</p>}
                <div style={{ display: "flex", gap: "0.5rem" }}>
                  <button class="btn btn-primary" type="submit" disabled={updatingNote()}>
                    {updatingNote() ? "Gemmer..." : "Gem"}
                  </button>
                  <button class="btn" type="button" onClick={() => setEditingNote(false)}>
                    Annuller
                  </button>
                </div>
              </form>
            </Show>
            <Show when={!editingNote() && me()?.note}>
              <div style={{ display: "flex", gap: "0.5rem", "align-items": "center", "margin-top": "0.5rem" }}>
                <p class="muted small" style={{ margin: 0 }}>Note: {me()?.note}</p>
                <button class="btn" type="button" onClick={() => setEditingNote(true)} style={{ padding: "0.25rem 0.5rem", "font-size": "0.875rem" }}>
                  Rediger
                </button>
              </div>
            </Show>
            <Show when={!editingNote() && !me()?.note}>
              <button class="btn" type="button" onClick={() => setEditingNote(true)} style={{ "margin-top": "0.5rem", padding: "0.25rem 0.5rem", "font-size": "0.875rem" }}>
                Tilføj note
              </button>
            </Show>
          </div>
        </Show>

        <Show when={!boot() && !doneMsg() && !me()?.authenticated}>
          <form class="form" onSubmit={onJoin}>
            <label class="field">
              <span class="field-label">Dit navn</span>
              <input
                class="input"
                name="name"
                autocomplete="name"
                placeholder="Fx Anna"
                value={name()}
                onInput={(ev) => setName(ev.currentTarget.value)}
                required
                minLength={1}
                maxLength={30}
              />
            </label>
            <label class="field">
              <span class="field-label">Note</span>
              <input
                class="input"
                name="note"
                placeholder="Fx 'Er ved lokale 1.20'"
                value={note()}
                onInput={(ev) => setNote(ev.currentTarget.value)}
                maxLength={30}
              />
            </label>
            {err() && <p class="form-error">{err()}</p>}
            <button class="btn btn-primary" type="submit" disabled={joining()}>
              {joining() ? "Tilmelder..." : "Stil dig i kø"}
            </button>
          </form>
        </Show>
      </div>
    </main>
  );
}
```

`api.js`
```js
const API_PREFIX = "/api";

export async function apiFetch(path, options = {}) {
  const { headers: headerInit, ...rest } = options;
  const headers = new Headers(headerInit);
  if (
    rest.body !== undefined &&
    rest.body !== null &&
    !headers.has("Content-Type")
  ) {
    headers.set("Content-Type", "application/json");
  }
  const url = path.startsWith("http") ? path : `${API_PREFIX}${path}`;
  const r = await fetch(url, {
    credentials: "include",
    ...rest,
    headers,
  });
  const text = await r.text();
  let data = null;
  if (text) {
    try {
      data = JSON.parse(text);
    } catch {
      data = text;
    }
  }
  if (!r.ok) {
    const msg =
      typeof data === "string"
        ? data.trim()
        : data?.message || r.statusText || `HTTP ${r.status}`;
    const err = new Error(msg);
    err.status = r.status;
    err.body = data;
    throw err;
  }
  return data;
}

export function listQueues() {
  return apiFetch("/queues", { method: "GET" });
}

export function login(username, password) {
  return apiFetch("/auth/login", {
    method: "POST",
    body: JSON.stringify({ username, password }),
  });
}

export function createQueue() {
  return apiFetch("/queues/new", { method: "POST", body: "{}" });
}

export function getQueue(id) {
  return apiFetch(`/queues/${id}`, { method: "GET" });
}

export function joinQueue(id, name, note) {
  return apiFetch(`/queues/${id}/join`, {
    method: "POST",
    body: JSON.stringify({ name, note }),
  });
}

export function markHelped(queueId, entryId) {
  return apiFetch(`/queues/${queueId}/mark-helped`, {
    method: "POST",
    body: JSON.stringify({ entry_id: entryId }),
  });
}

export function getQueueMe(queueId) {
  return apiFetch(`/queues/${queueId}/me`, { method: "GET" });
}

export function dismissStudentSession(queueId) {
  return apiFetch(`/queues/${queueId}/student/dismiss`, {
    method: "POST",
    body: "{}",
  });
}

export function updateNote(queueId, note) {
  return apiFetch(`/queues/${queueId}/note`, {
    method: "PATCH",
    body: JSON.stringify({ note }),
  });
}
```

`index.html`
```
<!doctype html>
<html lang="da">
  <head>
    <meta charset="UTF-8" />
    <link rel="icon" type="image/svg+xml" href="/favicon.svg" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <meta name="color-scheme" content="light" />
    <title>Vejledningskø</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/index.jsx"></script>
  </body>
</html>
```

`index.jsx`
```js
/* @refresh reload */
import { render } from 'solid-js/web'
import './index.css'
import App from './App.jsx'

const root = document.getElementById('root')

render(() => <App />, root)
```

`index.css`
```css
:root {
  color-scheme: light;
  --bg: #fafafa;
  --surface: #ffffff;
  --text: #334155;
  --text-strong: #0f172a;
  --muted: #64748b;
  --border: #e5e7eb;
  --primary: #2563eb;
  --primary-hover: #1d4ed8;
  --primary-soft: #eff6ff;
  --danger: #b91c1c;
  --danger-bg: #fef2f2;
  --success: #15803d;
  --success-bg: #f0fdf4;
  --radius: 8px;
  --radius-sm: 6px;
  --sans: system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif;
  --mono: ui-monospace, 'Cascadia Code', Consolas, monospace;

  font: 16px/1.5 var(--sans);
  color: var(--text);
  background: var(--bg);
  font-synthesis: none;
  text-rendering: optimizeLegibility;
  -webkit-font-smoothing: antialiased;
}

*,
*::before,
*::after {
  box-sizing: border-box;
}

body {
  margin: 0;
}

#root {
  min-height: 100svh;
}

.app-shell {
  min-height: 100svh;
  display: flex;
  flex-direction: column;
}

.page {
  width: 100%;
  max-width: 960px;
  margin: 0 auto;
  padding: clamp(1.25rem, 4vw, 2rem);
  text-align: left;
  flex: 1;
}

.page--narrow {
  max-width: 440px;
  display: flex;
  align-items: flex-start;
  justify-content: center;
  padding-top: clamp(2rem, 8vh, 3.5rem);
}

.page-header {
  display: flex;
  flex-wrap: wrap;
  align-items: flex-start;
  justify-content: space-between;
  gap: 1rem;
  margin-bottom: 1.25rem;
}

.page-header--stack {
  flex-direction: column;
}

.page-title {
  margin: 0 0 0.35rem;
  font-size: clamp(1.35rem, 3.5vw, 1.65rem);
  font-weight: 600;
  color: var(--text-strong);
}

.page-title--small {
  font-size: 1.2rem;
}

.app-title {
  margin: 0 0 0.5rem;
  font-size: 1.5rem;
  font-weight: 600;
  color: var(--text-strong);
}

.section-title {
  margin: 0 0 0.5rem;
  font-size: 1rem;
  font-weight: 600;
  color: var(--text-strong);
}

.lede {
  margin: 0 0 1.25rem;
  color: var(--muted);
  font-size: 0.95rem;
}

.muted {
  color: var(--muted);
}

.small {
  font-size: 0.875rem;
}

.card {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: 1.25rem 1.35rem;
}

.empty-state {
  text-align: center;
  padding: 2rem 1.5rem;
}

.breadcrumb {
  margin-bottom: 0.75rem;
}

.breadcrumb a {
  color: var(--primary);
  text-decoration: none;
  font-weight: 500;
  font-size: 0.9375rem;
}

.breadcrumb a:hover {
  text-decoration: underline;
}

.form {
  display: flex;
  flex-direction: column;
  gap: 1rem;
}

.field {
  display: flex;
  flex-direction: column;
  gap: 0.35rem;
  text-align: left;
}

.field-label {
  font-size: 0.875rem;
  font-weight: 500;
  color: var(--text-strong);
}

.input {
  width: 100%;
  padding: 0.6rem 0.75rem;
  border: 1px solid var(--border);
  border-radius: var(--radius-sm);
  font: inherit;
  color: var(--text-strong);
  background: #fff;
  transition: border-color 0.12s;
}

.input:focus {
  outline: none;
  border-color: var(--primary);
}

.form-error {
  margin: 0;
  color: var(--danger);
  font-size: 0.875rem;
}

.btn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 0.5rem;
  padding: 0.55rem 1rem;
  border-radius: var(--radius-sm);
  font: inherit;
  font-weight: 600;
  cursor: pointer;
  border: 1px solid transparent;
  transition: background 0.12s, border-color 0.12s, color 0.12s;
}

.btn:disabled {
  opacity: 0.6;
  cursor: not-allowed;
}

.btn-primary {
  background: var(--primary);
  color: #fff;
}

.btn-primary:hover:not(:disabled) {
  background: var(--primary-hover);
}

.btn-secondary {
  background: var(--surface);
  color: var(--text-strong);
  border-color: var(--border);
  margin-top: 0.75rem;
}

.btn-secondary:hover:not(:disabled) {
  background: var(--bg);
}

.banner {
  padding: 0.65rem 0.85rem;
  border-radius: var(--radius-sm);
  font-size: 0.875rem;
  margin: 0 0 1rem;
}

.banner-error {
  background: var(--danger-bg);
  color: var(--danger);
  border: 1px solid #fecaca;
}

.banner-success {
  background: var(--success-bg);
  color: var(--success);
  border: 1px solid #bbf7d0;
}

.queue-grid {
  list-style: none;
  margin: 0;
  padding: 0;
  display: grid;
  gap: 0.75rem;
}

@media (min-width: 560px) {
  .queue-grid {
    grid-template-columns: repeat(2, 1fr);
  }
}

.queue-card {
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  gap: 0.35rem;
  padding: 1rem 1.1rem;
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  text-decoration: none;
  color: inherit;
  transition: border-color 0.12s;
}

.queue-card:hover {
  border-color: #cbd5e1;
}

.queue-card-title {
  font-weight: 600;
  color: var(--text-strong);
}

.queue-card-wait {
  margin-top: 0.35rem;
  display: flex;
  align-items: baseline;
  gap: 0.4rem;
  font-size: 0.9375rem;
}

.queue-card-wait strong {
  font-size: 1.2rem;
  color: var(--text-strong);
  font-weight: 600;
}

.queue-detail-grid {
  display: grid;
  gap: 1.25rem;
}

@media (min-width: 800px) {
  .queue-detail-grid {
    grid-template-columns: 280px 1fr;
    align-items: start;
  }
}

.qr-wrap {
  display: flex;
  justify-content: center;
  padding: 0.75rem 0 1rem;
}

.qr-wrap img {
  display: block;
  border-radius: var(--radius-sm);
  border: 1px solid var(--border);
}

.entry-list {
  list-style: none;
  margin: 0.5rem 0 0;
  padding: 0;
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
}

.entry-row {
  width: 100%;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.75rem;
  padding: 0.65rem 0.85rem;
  border: 1px solid var(--border);
  border-radius: var(--radius-sm);
  background: #fff;
  font: inherit;
  text-align: left;
  cursor: pointer;
  transition: background 0.12s, border-color 0.12s;
}

.entry-row:hover:not(:disabled) {
  background: var(--bg);
  border-color: #cbd5e1;
}

.entry-row--done {
  opacity: 0.55;
  text-decoration: line-through;
  cursor: default;
  background: var(--bg);
}

.entry-row--done .entry-meta {
  text-decoration: none;
}

.entry-row--pending {
  opacity: 0.7;
  pointer-events: none;
}

.entry-name {
  font-weight: 500;
  color: var(--text-strong);
}

.entry-meta {
  font-size: 0.8125rem;
  color: var(--muted);
  flex-shrink: 0;
}

.wait-status {
  padding: 0.5rem 0 0.25rem;
}

.wait-greeting {
  margin: 0 0 0.35rem;
  font-size: 1.05rem;
  font-weight: 600;
  color: var(--text-strong);
}

.wait-place {
  margin: 0 0 0.35rem;
  font-size: 1rem;
}

.wait-place strong {
  color: var(--text-strong);
  font-size: 1.2rem;
  font-weight: 600;
}
```

== Anden kode

`Dockerfile`
```dockerfile
FROM oven/bun:1 AS frontend

WORKDIR /app/frontend/
COPY frontend/ /app/frontend/
RUN bun install
RUN bun run build

FROM golang:1-alpine

WORKDIR /app
COPY --from=frontend /app/frontend/dist static/
COPY go.* .
RUN go mod download -x

COPY . .

RUN go build -o /bin/app .

CMD ["/bin/app"]
```

`docker-compose.yml`
```yml
services:
  db:
    image: postgres:18-alpine
    environment:
      POSTGRES_USER: app
      POSTGRES_PASSWORD: app
      POSTGRES_DB: app
    volumes:
      - ./data:/var/lib/postgresql/18/docker

  app:
    build: .
    depends_on:
      - db
    ports:
      - "8080:8080"
    environment:
      DATABASE_URL: "postgres://app:app@db:5432/app"
```
