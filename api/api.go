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
