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

export default function QueueDetail() {
  const params = useParams();
  const queueId = () => params.id;
  const [qrSrc, setQrSrc] = createSignal("");
  const [actionErr, setActionErr] = createSignal("");
  const [pendingId, setPendingId] = createSignal(null);

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
                <ul class="entry-list">
                  {(() => {
                    let waitingPlace = 0;
                    return (q().entries ?? []).map((e) => {
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
                            </span>
                            <span class="entry-meta">
                              {done
                                ? "Fik hjælp " +
                                  new TimeAgo("da").format(
                                    new Date(e.helped_at),
                                  )
                                : pendingId() === e.id
                                  ? "…"
                                  : "Marker færdig"}
                            </span>
                          </button>
                        </li>
                      );
                    });
                  })()}
                </ul>
                {(q().entries ?? []).length === 0 && (
                  <p class="muted">Ingen i køen endnu.</p>
                )}
              </section>
            </div>
          </>
        )}
      </Show>
    </main>
  );
}
