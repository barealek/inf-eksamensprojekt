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
