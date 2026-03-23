-- Teachers, sessions, queues, entries (UUIDs from application).

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
    teacher_id UUID REFERENCES teachers (id) ON DELETE CASCADE;
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
    student_secret TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    helped_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_queue_entries_queue_id ON queue_entries (queue_id);
