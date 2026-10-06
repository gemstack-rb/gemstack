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
 *   const status = useRealtimeStatus();    // idle | connecting | open | reconnecting | offline
 *
 * One connection per tab to `<api path>/realtime` on the API's origin (the
 * page's own origin unless NEXT_PUBLIC_GEMSTACK_API_URL says otherwise), so
 * the session cookie authenticates it. Two transports, same features:
 *
 *   websocket  one WebSocket carries subscriptions, events, presence and send()
 *   sse        an EventSource stream for the subscribed channels (reopened
 *              when they change), and send() as a POST
 *
 * NEXT_PUBLIC_GEMSTACK_REALTIME picks one: "auto" (default: WebSocket, then
 * Server-Sent Events if a WebSocket can't be opened — e.g. a proxy that
 * doesn't pass WebSocket upgrades), "websocket" or "sse".
 *
 * It connects when the first channel is subscribed and closes after the last
 * one goes. If it drops, it reconnects with backoff (at once when the browser
 * comes back online) and resubscribes; the server replays what was missed, or
 * sends `gemstack.gap` to the channel's handlers when it can't, so you can
 * refetch. A refused channel's handlers get `gemstack.denied`.
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
export type RealtimeStatus = "idle" | "connecting" | "open" | "reconnecting" | "offline";
export type RealtimeTransport = "websocket" | "sse";
export type RealtimeMode = RealtimeTransport | "auto";
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

type ErrorBody = { code: string; message: string };

// WebSocket messages.
type ServerMessage =
  | { type: "welcome"; connection_id: string; heartbeat: number }
  | { type: "subscribed"; channel: string; presence?: PresenceEntry[] }
  | { type: "unsubscribed"; channel: string }
  | { type: "denied"; channel: string; code: string }
  | { type: "event"; id: string; channel: string; event: string; data: unknown }
  | { type: "gap"; channel: string }
  | { type: "presence"; channel: string; event: "join" | "leave"; id: string; meta?: Record<string, unknown> }
  | { type: "reply"; ref: number; ok: boolean; data?: unknown; error?: ErrorBody }
  | { type: "error"; code: string; message: string; ref?: number }
  | { type: "pong" };

// Server-Sent Events: the application's events, plus gemstack.* and presence.* ones.
type StreamMessage = { id: string | null; channel: string | null; event: string; data: unknown };

type Outgoing = { type: string; channel?: string; event?: string; data?: unknown; ref?: number; last_id?: string };
type Pending = { resolve: (data: unknown) => void; reject: (error: Error) => void; timer: ReturnType<typeof setTimeout> };

const MAX_BACKOFF_MS = 30_000;
const PING_EVERY_MS = 25_000;
const WEBSOCKET_OPEN_TIMEOUT_MS = 5_000; // auto: then use Server-Sent Events
const REOPEN_DELAY_MS = 50; // Server-Sent Events: one reopen for a burst of subscription changes

function configuredMode(): RealtimeMode {
  const mode = process.env.NEXT_PUBLIC_GEMSTACK_REALTIME;
  return mode === "websocket" || mode === "sse" ? mode : "auto";
}

function endpoint(): string {
  return apiUrl("/realtime");
}

function crossOrigin(): boolean {
  return /^https?:/i.test(endpoint());
}

function websocketUrl(): string {
  const url = endpoint();
  if (/^https?:/i.test(url)) return url.replace(/^http/i, "ws");
  const scheme = window.location.protocol === "https:" ? "wss:" : "ws:";
  return `${scheme}//${window.location.host}${url}`;
}

function browserOffline(): boolean {
  return typeof navigator !== "undefined" && navigator.onLine === false;
}

export class RealtimeClient {
  status: RealtimeStatus = "idle";
  /** The transport of the open connection. */
  transport: RealtimeTransport | null = null;
  readonly mode: RealtimeMode;
  private socket: WebSocket | null = null;
  private stream: EventSource | null = null;
  private handlers = new Map<string, Set<RealtimeHandler>>();
  private lastIds = new Map<string, string>();
  private lastStreamId: string | null = null;
  private seen = new Map<string, Set<string>>();
  private presence = new Map<string, Map<string, PresenceEntry>>();
  private pending = new Map<number, Pending>();
  private outbox: Outgoing[] = [];
  private listeners = new Set<() => void>();
  private nextRef = 1;
  private attempts = 0;
  private heartbeatMs = 15_000;
  private lastMessageAt = 0;
  private websocketWorks = false; // auto: a WebSocket opened, so a later drop is just a drop
  private websocketFailed = false; // auto: none ever opened, so this page uses Server-Sent Events
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private reopenTimer: ReturnType<typeof setTimeout> | null = null;
  private openTimer: ReturnType<typeof setTimeout> | null = null;
  private pingTimer: ReturnType<typeof setInterval> | null = null;
  private closeScheduled = false;

  constructor(mode: RealtimeMode = configuredMode()) {
    this.mode = mode;
  }

  subscribe<T = unknown>(channel: string, handler: RealtimeHandler<T>): () => void {
    let set = this.handlers.get(channel);
    if (!set) {
      set = new Set();
      this.handlers.set(channel, set);
      this.subscriptionsChanged({ type: "subscribe", channel, last_id: this.lastIds.get(channel) });
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
      this.subscriptionsChanged({ type: "unsubscribe", channel });
      this.notify();
      this.scheduleIdleClose();
    };
  }

  /** Sends a message to a channel's `receive` handler; resolves with its return value. */
  send<T = unknown>(channel: string, event: string, data?: unknown, { timeout = 10_000 } = {}): Promise<T> {
    const ref = this.nextRef++;
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(ref);
        reject(new RealtimeError("timeout", `no reply to ${event} on ${channel}`));
      }, timeout);
      this.pending.set(ref, { resolve: resolve as (data: unknown) => void, reject, timer });
      const message = { type: "message", channel, event, data, ref };
      if (this.preferred() === "sse") {
        void this.post(message);
      } else {
        this.write(message);
        this.ensureConnected();
      }
    });
  }

  /** Who's on a presence channel (empty until the subscription is confirmed). */
  presenceOf(channel: string): PresenceEntry[] {
    return [...(this.presence.get(channel)?.values() ?? [])];
  }

  /** Reconnects now instead of waiting for the backoff (called when the browser comes back online). */
  reconnectNow() {
    if (this.socket || this.stream) return;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.reconnectTimer = null;
    this.attempts = 0;
    this.connect();
  }

  /** Drops the connection until reconnectNow() (called when the browser goes offline). */
  wentOffline() {
    this.disconnect();
    if (this.wanted()) this.setStatus("offline");
  }

  /** Calls listener(status) whenever the connection status changes. */
  onStatus(listener: (status: RealtimeStatus) => void): () => void {
    let last = this.status;
    return this.onChange(() => {
      if (this.status !== last) listener((last = this.status));
    });
  }

  /** Re-renders on status and presence changes (for hooks). */
  onChange(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  // ── connection ───────────────────────────────────────────────────────

  private preferred(): RealtimeTransport {
    if (this.mode === "sse" || typeof WebSocket === "undefined") return "sse";
    if (this.mode === "websocket") return "websocket";
    return this.websocketFailed ? "sse" : "websocket";
  }

  // A stream only carries subscriptions; a WebSocket also carries send().
  private wanted(): boolean {
    return this.handlers.size > 0 || (this.preferred() === "websocket" && this.pending.size > 0);
  }

  private ensureConnected() {
    if (typeof window === "undefined") return;
    if (this.socket || this.stream || this.reconnectTimer || this.status === "offline") return;
    if (this.preferred() === "websocket") return this.connect();
    // Let the components mounting together subscribe first: one stream for all of them.
    this.setStatus("connecting");
    this.reconnectTimer = setTimeout(() => this.connect(), 0);
  }

  private connect(reopening = false) {
    this.reconnectTimer = null;
    if (!this.wanted()) return this.setStatus("idle");
    if (browserOffline()) return this.setStatus("offline");

    if (!reopening) this.setStatus(this.attempts === 0 ? "connecting" : "reconnecting");
    if (this.preferred() === "websocket") this.openSocket();
    else this.openStream();
  }

  private retry() {
    if (!this.wanted()) return this.setStatus("idle");
    if (browserOffline()) return this.setStatus("offline");
    // Exponential backoff with jitter: 0.5 s, 1 s, 2 s … up to 30 s.
    const delay = Math.min(MAX_BACKOFF_MS, 500 * 2 ** this.attempts) * (0.5 + Math.random() / 2);
    this.attempts++;
    this.setStatus("reconnecting");
    this.reconnectTimer = setTimeout(() => this.connect(), delay);
  }

  private opened(transport: RealtimeTransport, heartbeat: number) {
    this.attempts = 0;
    this.transport = transport;
    this.heartbeatMs = heartbeat * 1000;
    this.setStatus("open");
    if (this.pingTimer) clearInterval(this.pingTimer);
    this.pingTimer = setInterval(() => this.ping(), PING_EVERY_MS);
  }

  // A connection that has been silent for three heartbeats is dead: replace it.
  private ping() {
    if (Date.now() - this.lastMessageAt > this.heartbeatMs * 3) {
      if (this.socket) return this.socket.close();
      if (this.stream) return this.streamDropped(this.stream);
    }
    if (this.socket) this.write({ type: "ping" });
  }

  private disconnect() {
    for (const timer of [this.reconnectTimer, this.reopenTimer, this.openTimer]) if (timer) clearTimeout(timer);
    if (this.pingTimer) clearInterval(this.pingTimer);
    this.reconnectTimer = this.reopenTimer = this.openTimer = this.pingTimer = null;
    const { socket, stream } = this;
    this.socket = null;
    this.stream = null;
    socket?.close(1000);
    stream?.close();
  }

  private scheduleIdleClose() {
    if (this.closeScheduled) return;
    this.closeScheduled = true;
    setTimeout(() => {
      this.closeScheduled = false;
      if (this.wanted()) return;
      this.outbox = [];
      this.disconnect();
      this.setStatus("idle");
    }, 1000);
  }

  private subscriptionsChanged(message: Outgoing) {
    if (this.preferred() === "websocket") return this.write(message);
    // The stream's URL lists its channels: reopen it (presence rides out a quick reopen).
    if (!this.stream || this.reopenTimer) return;
    this.reopenTimer = setTimeout(() => {
      this.reopenTimer = null;
      const stream = this.stream;
      if (!stream) return;
      this.stream = null;
      stream.close();
      this.connect(true);
    }, REOPEN_DELAY_MS);
  }

  // ── WebSocket ────────────────────────────────────────────────────────

  private openSocket() {
    const socket = new WebSocket(websocketUrl());
    this.socket = socket;
    socket.onmessage = (message) => this.receive(message.data);
    // Either one means it's gone (some runtimes skip `close` after a failed handshake).
    socket.onclose = () => this.socketDropped(socket);
    socket.onerror = () => this.socketDropped(socket);
    if (this.mode === "auto" && !this.websocketWorks) {
      this.openTimer = setTimeout(() => socket.close(), WEBSOCKET_OPEN_TIMEOUT_MS);
    }
  }

  private socketDropped(socket: WebSocket) {
    if (this.socket !== socket) return;
    this.socket = null;
    if (this.openTimer) clearTimeout(this.openTimer);
    if (this.pingTimer) clearInterval(this.pingTimer);
    this.openTimer = this.pingTimer = null;
    if (this.mode === "auto" && !this.websocketWorks && !browserOffline()) return this.fallBackToStream();
    this.retry();
  }

  // auto: no WebSocket got through (a proxy in the way), so this page uses
  // Server-Sent Events from now on.
  private fallBackToStream() {
    this.websocketFailed = true;
    console.info("[realtime] WebSocket unavailable; using Server-Sent Events");
    const queued = this.outbox.filter((message) => message.type === "message");
    this.outbox = [];
    queued.forEach((message) => void this.post(message));
    this.connect();
  }

  private socketOpened(heartbeat: number) {
    if (this.openTimer) clearTimeout(this.openTimer);
    this.openTimer = null;
    this.websocketWorks = true;
    this.opened("websocket", heartbeat);
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
  }

  private write(message: Outgoing) {
    if (this.socket?.readyState === WebSocket.OPEN && this.status === "open") this.socket.send(JSON.stringify(message));
    else if (message.type !== "ping") this.outbox.push(message);
  }

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
        return this.socketOpened(message.heartbeat);
      case "event":
        return this.event(message);
      case "gap":
        return this.emit(message.channel, { id: null, channel: message.channel, event: GAP_EVENT, data: null });
      case "denied":
        return this.emit(message.channel, { id: null, channel: message.channel, event: DENIED_EVENT, data: message.code });
      case "subscribed":
        if (message.presence) this.presenceState(message.channel, message.presence);
        return;
      case "presence":
        return this.presenceChange(message.channel, message.event, message.id, message.meta);
      case "reply":
        return this.reply(message.ref, message.ok, message.data, message.error);
      case "error":
        if (message.ref !== undefined) this.reply(message.ref, false, undefined, message);
        else console.warn(`[realtime] ${message.code}: ${message.message}`);
    }
  }

  // ── Server-Sent Events ───────────────────────────────────────────────

  private openStream() {
    if (typeof EventSource === "undefined") return this.setStatus("idle");
    const query = new URLSearchParams({ channels: [...this.handlers.keys()].join(",") });
    if (this.lastStreamId) query.set("last_event_id", this.lastStreamId);
    const stream = new EventSource(`${endpoint()}?${query}`, { withCredentials: crossOrigin() });
    this.stream = stream;
    stream.onmessage = (message) => this.receiveStream(message.data);
    // Reconnect on this client's schedule and with the current channels, not EventSource's.
    stream.onerror = () => this.streamDropped(stream);
  }

  private streamDropped(stream: EventSource) {
    stream.close();
    if (this.stream !== stream) return;
    this.stream = null;
    if (this.pingTimer) clearInterval(this.pingTimer);
    this.pingTimer = null;
    this.retry();
  }

  private receiveStream(raw: string) {
    this.lastMessageAt = Date.now();
    let message: StreamMessage;
    try {
      message = JSON.parse(raw) as StreamMessage;
    } catch {
      return;
    }
    const channel = message.channel ?? "";
    switch (message.event) {
      case "gemstack.welcome":
        return this.opened("sse", (message.data as { heartbeat: number }).heartbeat);
      case "gemstack.ping":
        return;
      case "gemstack.presence":
        return this.presenceState(channel, message.data as PresenceEntry[]);
      case "presence.join":
      case "presence.leave": {
        const entry = message.data as PresenceEntry;
        return this.presenceChange(channel, message.event === "presence.join" ? "join" : "leave", entry.id, entry.meta);
      }
      case DENIED_EVENT:
        return this.emit(channel, { id: null, channel, event: DENIED_EVENT, data: message.data });
      case GAP_EVENT: // for every channel on the stream
        return this.handlers.forEach((_, name) => this.emit(name, { id: null, channel: name, event: GAP_EVENT, data: null }));
      default:
        if (!message.id || !message.channel) return;
        this.lastStreamId = message.id;
        this.event({ id: message.id, channel: message.channel, event: message.event, data: message.data });
    }
  }

  private async post(message: Outgoing) {
    const ref = message.ref as number;
    try {
      const response = await fetch(endpoint(), {
        method: "POST",
        headers: { "content-type": "application/json", accept: "application/json" },
        body: JSON.stringify({ channel: message.channel, event: message.event, data: message.data }),
        credentials: crossOrigin() ? "include" : "same-origin",
      });
      const body = (await response.json().catch(() => null)) as { data?: unknown; error?: ErrorBody } | null;
      if (response.ok) this.reply(ref, true, body?.data);
      else this.reply(ref, false, undefined, body?.error ?? { code: "http_error", message: `HTTP ${response.status}` });
    } catch (error) {
      this.reply(ref, false, undefined, { code: "network_error", message: String(error) });
    }
  }

  // ── both ─────────────────────────────────────────────────────────────

  private event(message: { id: string; channel: string; event: string; data: unknown }) {
    // A replay can overlap with live delivery right after (re)subscribing.
    const seen = this.seen.get(message.channel) ?? new Set<string>();
    if (seen.has(message.id)) return;
    seen.add(message.id);
    if (seen.size > 200) seen.delete(seen.values().next().value as string);
    this.seen.set(message.channel, seen);
    this.lastIds.set(message.channel, message.id);
    this.emit(message.channel, { id: message.id, channel: message.channel, event: message.event, data: message.data });
  }

  private presenceState(channel: string, entries: PresenceEntry[]) {
    if (!this.handlers.has(channel)) return;
    this.presence.set(channel, new Map(entries.map((entry) => [entry.id, entry])));
    this.notify();
  }

  private presenceChange(channel: string, change: "join" | "leave", id: string, meta?: Record<string, unknown>) {
    const entries = this.presence.get(channel);
    if (!entries) return;
    if (change === "join") entries.set(id, { id, meta });
    else entries.delete(id);
    this.presence.set(channel, new Map(entries)); // a new Map, so hooks see a change
    this.notify();
  }

  private reply(ref: number, ok: boolean, data: unknown, error?: ErrorBody) {
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
    if (status !== "open" && !this.socket && !this.stream) this.transport = null;
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
  window.addEventListener("offline", () => realtime.wentOffline());
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

/** "idle" | "connecting" | "open" | "reconnecting" | "offline" — e.g. to show an offline banner. */
export function useRealtimeStatus(): RealtimeStatus {
  return useSyncExternalStore(
    (listener) => realtime.onChange(listener),
    () => realtime.status,
    () => "idle",
  );
}
