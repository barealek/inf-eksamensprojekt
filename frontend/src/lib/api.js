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

export function register(username, password) {
  return apiFetch("/auth/register", {
    method: "POST",
    body: JSON.stringify({ username, password }),
  });
}
