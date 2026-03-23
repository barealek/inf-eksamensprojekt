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
	ID          uuid.UUID
	Username    string
	PasswordHash string
	CreatedAt   time.Time
	LastLoginAt *time.Time
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
	CreatedAt   time.Time
	HelpedAt    *time.Time
}

// AddQueueEntry appends a student; studentSecret is stored for later cookie checks.
func (db *DB) AddQueueEntry(ctx context.Context, queueID uuid.UUID, displayName, studentSecret string) (*QueueEntry, error) {
	id := uuid.New()
	var e QueueEntry
	err := db.Pool.QueryRow(ctx,
		`INSERT INTO queue_entries (id, queue_id, display_name, student_secret)
		 VALUES ($1, $2, $3, $4)
		 RETURNING id, queue_id, display_name, created_at`,
		id, queueID, displayName, studentSecret,
	).Scan(&e.ID, &e.QueueID, &e.DisplayName, &e.CreatedAt)
	if err != nil {
		return nil, err
	}
	return &e, nil
}

// ListQueueEntries returns entries for a queue (no secrets). Waiting first, then helped.
func (db *DB) ListQueueEntries(ctx context.Context, queueID uuid.UUID) ([]QueueEntry, error) {
	rows, err := db.Pool.Query(ctx,
		`SELECT id, queue_id, display_name, created_at, helped_at
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
		if err := rows.Scan(&e.ID, &e.QueueID, &e.DisplayName, &e.CreatedAt, &helped); err != nil {
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
		`SELECT id, queue_id, display_name, created_at, helped_at
		 FROM queue_entries WHERE id = $1`,
		entryID,
	).Scan(&e.ID, &e.QueueID, &e.DisplayName, &e.CreatedAt, &helped)
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
