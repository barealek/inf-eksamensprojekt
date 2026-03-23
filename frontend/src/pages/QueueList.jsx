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
                    Kø fra kl. {new Date(q.created_at).toLocaleTimeString()}
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
