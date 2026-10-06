/**
 * GemStack realtime client (yours to edit — see docs/realtime.md).
 *
 *   const off = realtime.subscribe("orders:42", (event) => console.log(event.event, event.data));
 *   off(); // unsubscribe
 *
 *   await realtime.send("rooms:1", "message.create", { body: "Hi" }); // handled by `receive` in config/channels.rb
 *
 *   useRealtime("products", () => queryClient.invalidateQueries({ queryKey: ["products"] }));
 *   const people = usePresence("rooms:1"); // [{ id, meta }] — channels declared with presence: true
 *
 * One WebSocket per tab, to `<api path>/realtime` on the API's origin (the
 * page's own origin unless NEXT_PUBLIC_GEMSTACK_API_URL says otherwise), so
 * the session cookie authenticates it. It connects when the first channel is
 * subscribed and closes after the last one goes. If it drops, it reconnects
 * with backoff and resubscribes; the server replays what was missed, or sends
 * `gemstack.gap` to the channel's handlers when it can't, so you can refetch.
 * A refused channel's handlers get `gemstack.denied`.
 */
"use client";

import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { apiUrl } from "./client";

export type RealtimeEvent<T = unknown> = {
  id: string | null;
  channel: string;
  event: string;
  data: T;
};

export type RealtimeHandler<T = unknown> = (event: RealtimeEvent<T>) => void;
export type RealtimeStatus = "idle" | "connecting" | "open" | "reconnecting";
export type PresenceEntry<M = Record<string, unknown>> = { id: string; meta?: M };

/** Delivered to a channel's handlers when events were missed and can't be replayed: refetch. */
export const GAP_EVENT = "gemstack.gap";
/** Delivered to a channel's handlers when the server refuses the subscription. */
export const DENIED_EVENT = "gemstack.denied";

/** A `realtime.send` the server refused or couldn't handle. */
export class RealtimeError extends Error {
  readonly code: string;
  constructor(code: string, message: string) {
    super(message);
    this.name = "RealtimeError";
    this.code = code;
  }
}

type ServerMessage =
  | { type: "welcome"; connection_id: string; heartbeat: number }
  | { type: "subscribed"; channel: string; presence?: PresenceEntry[] }
  | { type: "unsubscribed"; channel: string }
  | { type: "denied"; channel: string; code: string }
  | { type: "event"; id: string; channel: string; event: string; data: unknown }
  | { type: "gap"; channel: string }
  | { type: "presence"; channel: string; event: "join" | "leave"; id: string; meta?: Record<string, unknown> }
  | { type: "reply"; ref: number; ok: boolean; data?: unknown; error?: { code: string; message: string } }
  | { type: "error"; code: string; message: string; ref?: number }
  | { type: "pong" };

type Pending = { resolve: (data: unknown) => void; reject: (error: Error) => void; timer: ReturnType<typeof setTimeout> };

const MAX_BACKOFF_MS = 30_000;
const PING_EVERY_MS = 25_000;

function realtimeUrl(): string {
  const url = apiUrl("/realtime");
  if (/^https?:/i.test(url)) return url.replace(/^http/i, "ws");
  const scheme = window.location.protocol === "https:" ? "wss:" : "ws:";
  return `${scheme}//${window.location.host}${url}`;
}

class RealtimeClient {
  status: RealtimeStatus = "idle";
  private socket: WebSocket | null = null;
  private handlers = new Map<string, Set<RealtimeHandler>>();
  private lastIds = new Map<string, string>();
  private seen = new Map<string, Set<string>>();
  private presence = new Map<string, Map<string, PresenceEntry>>();
  private pending = new Map<number, Pending>();
  private outbox: Record<string, unknown>[] = [];
  private listeners = new Set<() => void>();
  private nextRef = 1;
  private attempts = 0;
  private heartbeatMs = 15_000;
  private lastMessageAt = 0;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private pingTimer: ReturnType<typeof setInterval> | null = null;
  private closeScheduled = false;

  subscribe<T = unknown>(channel: string, handler: RealtimeHandler<T>): () => void {
    let set = this.handlers.get(channel);
    if (!set) {
      set = new Set();
      this.handlers.set(channel, set);
      this.write({ type: "subscribe", channel, last_id: this.lastIds.get(channel) });
    }
    set.add(handler as RealtimeHandler);
    this.ensureConnected();
    return () => {
      set.delete(handler as RealtimeHandler);
      if (set.size > 0 || this.handlers.get(channel) !== set) return;
      this.handlers.delete(channel);
      this.presence.delete(channel);
      this.lastIds.delete(channel);
      this.seen.delete(channel);
      this.write({ type: "unsubscribe", channel });
      this.notify();
      this.scheduleIdleClose();
    };
  }

  /** Sends a message to a subscribed channel; resolves with the `receive` handler's reply. */
  send<T = unknown>(channel: string, event: string, data?: unknown, { timeout = 10_000 } = {}): Promise<T> {
    const ref = this.nextRef++;
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(ref);
        reject(new RealtimeError("timeout", `no reply to ${event} on ${channel}`));
      }, timeout);
      this.pending.set(ref, { resolve: resolve as (data: unknown) => void, reject, timer });
      this.write({ type: "message", channel, event, data, ref });
      this.ensureConnected();
    });
  }

  /** Who's on a presence channel (empty until the subscription is confirmed). */
  presenceOf(channel: string): PresenceEntry[] {
    return [...(this.presence.get(channel)?.values() ?? [])];
  }

  /** Skips the backoff wait, e.g. when the browser comes back online. */
  reconnectNow() {
    if (!this.reconnectTimer) return;
    clearTimeout(this.reconnectTimer);
    this.connect();
  }

  /** Re-renders on status and presence changes (for hooks). */
  onChange(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  // ── connection ───────────────────────────────────────────────────────

  private ensureConnected() {
    if (typeof window === "undefined" || typeof WebSocket === "undefined") return;
    if (this.socket || this.reconnectTimer) return;
    this.connect();
  }

  private connect() {
    this.reconnectTimer = null;
    if (this.handlers.size === 0 && this.pending.size === 0) return this.setStatus("idle");

    this.setStatus(this.attempts === 0 ? "connecting" : "reconnecting");
    const socket = new WebSocket(realtimeUrl());
    this.socket = socket;
    socket.onmessage = (message) => this.receive(message.data);
    socket.onclose = () => this.dropped(socket);
    socket.onerror = () => socket.close();
  }

  private dropped(socket: WebSocket) {
    if (this.socket !== socket) return;
    this.socket = null;
    if (this.pingTimer) clearInterval(this.pingTimer);
    this.pingTimer = null;
    if (this.handlers.size === 0 && this.pending.size === 0) return this.setStatus("idle");

    // Exponential backoff with jitter: 0.5 s, 1 s, 2 s … up to 30 s.
    const delay = Math.min(MAX_BACKOFF_MS, 500 * 2 ** this.attempts) * (0.5 + Math.random() / 2);
    this.attempts++;
    this.setStatus("reconnecting");
    this.reconnectTimer = setTimeout(() => this.connect(), delay);
  }

  private opened(heartbeat: number) {
    this.attempts = 0;
    this.heartbeatMs = heartbeat * 1000;
    this.setStatus("open");
    // Resubscribe everything (with the last event seen, for replay), then flush what waited.
    const resubscribe = [...this.handlers.keys()].map((channel) => ({
      type: "subscribe",
      channel,
      last_id: this.lastIds.get(channel),
    }));
    // Queued (un)subscribes are superseded by the current subscriptions above.
    const queued = this.outbox.filter((message) => message.type !== "subscribe" && message.type !== "unsubscribe");
    this.outbox = [];
    [...resubscribe, ...queued].forEach((message) => this.socket?.send(JSON.stringify(message)));
    if (this.pingTimer) clearInterval(this.pingTimer);
    this.pingTimer = setInterval(() => this.ping(), PING_EVERY_MS);
  }

  // A connection that has been silent for three heartbeats is dead: replace it.
  private ping() {
    if (Date.now() - this.lastMessageAt > this.heartbeatMs * 3) return this.socket?.close();
    this.write({ type: "ping" });
  }

  private write(message: Record<string, unknown>) {
    if (this.socket?.readyState === WebSocket.OPEN && this.status === "open") this.socket.send(JSON.stringify(message));
    else this.outbox.push(message);
  }

  private scheduleIdleClose() {
    if (this.closeScheduled) return;
    this.closeScheduled = true;
    setTimeout(() => {
      this.closeScheduled = false;
      if (this.handlers.size > 0 || this.pending.size > 0) return;
      if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
      this.outbox = [];
      this.socket?.close(1000);
      this.socket = null;
      this.setStatus("idle");
    }, 1000);
  }

  // ── messages ─────────────────────────────────────────────────────────

  private receive(raw: unknown) {
    this.lastMessageAt = Date.now();
    let message: ServerMessage;
    try {
      message = JSON.parse(String(raw)) as ServerMessage;
    } catch {
      return;
    }
    switch (message.type) {
      case "welcome":
        return this.opened(message.heartbeat);
      case "event":
        return this.event(message);
      case "gap":
        return this.emit(message.channel, { id: null, channel: message.channel, event: GAP_EVENT, data: null });
      case "denied":
        return this.emit(message.channel, { id: null, channel: message.channel, event: DENIED_EVENT, data: message.code });
      case "subscribed":
        if (message.presence) {
          this.presence.set(message.channel, new Map(message.presence.map((entry) => [entry.id, entry])));
          this.notify();
        }
        return;
      case "presence":
        return this.presenceChange(message);
      case "reply":
        return this.reply(message.ref, message.ok, message.data, message.error);
      case "error":
        if (message.ref !== undefined) this.reply(message.ref, false, undefined, message);
        else console.warn(`[realtime] ${message.code}: ${message.message}`);
    }
  }

  private event(message: Extract<ServerMessage, { type: "event" }>) {
    // A replay can overlap with live delivery right after (re)subscribing.
    const seen = this.seen.get(message.channel) ?? new Set<string>();
    if (seen.has(message.id)) return;
    seen.add(message.id);
    if (seen.size > 200) seen.delete(seen.values().next().value as string);
    this.seen.set(message.channel, seen);
    this.lastIds.set(message.channel, message.id);
    this.emit(message.channel, { id: message.id, channel: message.channel, event: message.event, data: message.data });
  }

  private presenceChange(message: Extract<ServerMessage, { type: "presence" }>) {
    const entries = this.presence.get(message.channel);
    if (!entries) return;
    if (message.event === "join") entries.set(message.id, { id: message.id, meta: message.meta });
    else entries.delete(message.id);
    this.presence.set(message.channel, new Map(entries)); // a new Map, so hooks see a change
    this.notify();
  }

  private reply(ref: number, ok: boolean, data: unknown, error?: { code: string; message: string }) {
    const pending = this.pending.get(ref);
    if (!pending) return;
    this.pending.delete(ref);
    clearTimeout(pending.timer);
    if (ok) pending.resolve(data);
    else pending.reject(new RealtimeError(error?.code ?? "error", error?.message ?? "the message was refused"));
    this.scheduleIdleClose();
  }

  private emit(channel: string, event: RealtimeEvent) {
    this.handlers.get(channel)?.forEach((handler) => handler(event));
  }

  private setStatus(status: RealtimeStatus) {
    if (this.status === status) return;
    this.status = status;
    this.notify();
  }

  private notify() {
    this.listeners.forEach((listener) => listener());
  }
}

export const realtime = new RealtimeClient();

if (typeof window !== "undefined") {
  // Back online: don't wait for the backoff timer.
  window.addEventListener("online", () => realtime.reconnectNow());
}

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

/** Who's on a presence channel; subscribes while mounted. */
export function usePresence<M = Record<string, unknown>>(channel: string | null): PresenceEntry<M>[] {
  useRealtime(channel, () => {});
  const [, rerender] = useState(0);
  useEffect(() => realtime.onChange(() => rerender((n) => n + 1)), []);
  return channel ? (realtime.presenceOf(channel) as PresenceEntry<M>[]) : [];
}

/** "idle" | "connecting" | "open" | "reconnecting" — e.g. to show an offline banner. */
export function useRealtimeStatus(): RealtimeStatus {
  return useSyncExternalStore(
    (listener) => realtime.onChange(listener),
    () => realtime.status,
    () => "idle",
  );
}
