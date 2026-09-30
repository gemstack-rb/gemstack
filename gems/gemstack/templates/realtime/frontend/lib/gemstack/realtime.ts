/**
 * GemStack realtime client (yours to edit — see docs/realtime.md).
 *
 *   const off = realtime.subscribe("orders:42", (event) => console.log(event.event, event.data));
 *   off(); // unsubscribe
 *
 *   useRealtime("products", (event) => queryClient.invalidateQueries({ queryKey: ["products"] }));
 *
 * One EventSource per tab carries every channel; changes to the set of
 * channels made in the same tick cause a single reconnect. After a dropped
 * connection the browser reconnects with Last-Event-ID and the server replays
 * what was missed — or sends `gemstack.gap` (delivered to every handler) when
 * it can't, so you can refetch. A refused channel's handlers get `gemstack.denied`
 * while the other channels keep working.
 */
"use client";

import { useEffect, useRef } from "react";
import { apiUrl } from "./client";

export type RealtimeEvent<T = unknown> = {
  id: string | null;
  channel: string | null;
  event: string;
  data: T;
};

export type RealtimeHandler<T = unknown> = (event: RealtimeEvent<T>) => void;
export type RealtimeStatus = "idle" | "connecting" | "open" | "reconnecting";

export const GAP_EVENT = "gemstack.gap";
/** Delivered to a channel's handlers when the server refuses the subscription. */
export const DENIED_EVENT = "gemstack.denied";

class RealtimeClient {
  private handlers = new Map<string, Set<RealtimeHandler>>();
  private source: EventSource | null = null;
  private connectedKey = "";
  private lastEventId: string | null = null;
  private scheduled = false;
  private statusListeners = new Set<(status: RealtimeStatus) => void>();
  status: RealtimeStatus = "idle";

  subscribe<T = unknown>(channel: string, handler: RealtimeHandler<T>): () => void {
    const set = this.handlers.get(channel) ?? new Set<RealtimeHandler>();
    set.add(handler as RealtimeHandler);
    this.handlers.set(channel, set);
    this.schedule();
    return () => {
      set.delete(handler as RealtimeHandler);
      if (set.size === 0) this.handlers.delete(channel);
      this.schedule();
    };
  }

  onStatus(listener: (status: RealtimeStatus) => void): () => void {
    this.statusListeners.add(listener);
    return () => this.statusListeners.delete(listener);
  }

  private setStatus(status: RealtimeStatus) {
    this.status = status;
    this.statusListeners.forEach((listener) => listener(status));
  }

  private schedule() {
    if (this.scheduled) return;
    this.scheduled = true;
    queueMicrotask(() => {
      this.scheduled = false;
      this.connect();
    });
  }

  private connect() {
    if (typeof window === "undefined" || typeof EventSource === "undefined") return;
    const channels = [...this.handlers.keys()].sort();
    const key = channels.join(",");
    if (key === this.connectedKey && this.source) return;

    this.source?.close();
    this.source = null;
    this.connectedKey = key;
    if (channels.length === 0) return this.setStatus("idle");

    const query: Record<string, string> = { channels: key };
    if (this.lastEventId) query.last_event_id = this.lastEventId;
    const source = new EventSource(apiUrl("/realtime", query), { withCredentials: true });
    this.source = source;
    this.setStatus("connecting");
    source.onopen = () => this.setStatus("open");
    source.onerror = () => this.setStatus("reconnecting"); // the browser retries on its own
    source.onmessage = (message) => {
      if (message.lastEventId) this.lastEventId = message.lastEventId;
      let event: RealtimeEvent;
      try {
        event = JSON.parse(message.data) as RealtimeEvent;
      } catch {
        return;
      }
      const targets =
        event.event === GAP_EVENT ? [...this.handlers.values()] : [this.handlers.get(event.channel ?? "") ?? new Set()];
      targets.forEach((set) => set.forEach((handler) => handler(event)));
    };
  }
}

export const realtime = new RealtimeClient();

/** Subscribes while the component is mounted. Pass null to skip. */
export function useRealtime<T = unknown>(channel: string | null, handler: RealtimeHandler<T>) {
  const latest = useRef(handler);
  useEffect(() => {
    latest.current = handler; // always call the newest handler without resubscribing
  });
  useEffect(() => {
    if (!channel) return;
    return realtime.subscribe<T>(channel, (event) => latest.current(event));
  }, [channel]);
}
