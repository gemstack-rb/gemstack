/**
 * GemStack API client runtime.
 *
 * This file belongs to your application (it is not a hidden dependency):
 * add auth headers, interceptors or logging here as needed.
 *
 * Where requests go:
 * - Browser: relative URLs ("/api/..."), i.e. the same origin — no CORS, no config.
 * - Server Components / Route Handlers: GEMSTACK_API_URL (injected by `gemstack dev`,
 *   set by you in production) so the Next.js server calls Ruby directly.
 * - API on another domain: set NEXT_PUBLIC_GEMSTACK_API_URL.
 */

export const API_PATH = process.env.NEXT_PUBLIC_GEMSTACK_API_PATH ?? "/api";

/** The JSON error envelope every GemStack API error uses. */
export interface ApiErrorBody {
  error: { code: string; message: string; request_id?: string };
  /** Field-level validation messages, e.g. { name: ["is required"] }. */
  errors?: Record<string, string[]>;
  /** Development only (config.http.show_exceptions): the server-side exception. */
  exception?: { class: string; message: string; backtrace: string[] };
}

export class ApiError extends Error {
  readonly status: number;
  readonly code: string;
  readonly requestId?: string;
  readonly errors: Record<string, string[]>;

  constructor(status: number, body: ApiErrorBody | null, fallbackMessage: string) {
    super(body?.error?.message ?? fallbackMessage);
    this.name = "ApiError";
    this.status = status;
    this.code = body?.error?.code ?? "http_error";
    this.requestId = body?.error?.request_id;
    this.errors = body?.errors ?? {};
  }

  /** True for 4xx responses: retrying the same request won't help. */
  get isClientError(): boolean {
    return this.status >= 400 && this.status < 500;
  }
}

type QueryValue = string | number | boolean | null | undefined;
export type Query = Record<string, QueryValue | QueryValue[]>;

export interface RequestOptions extends Omit<RequestInit, "body" | "method"> {
  query?: Query;
  body?: unknown;
}

function baseUrl(): string {
  const publicUrl = process.env.NEXT_PUBLIC_GEMSTACK_API_URL;
  if (publicUrl) return publicUrl.replace(/\/$/, "");
  if (typeof window === "undefined") {
    return (process.env.GEMSTACK_API_URL ?? "http://127.0.0.1:4000").replace(/\/$/, "");
  }
  return "";
}

/** Builds a URL for an API path: apiUrl("/products", { page: 2 }) → "/api/products?page=2". */
export function apiUrl(path: string, query?: Query): string {
  const normalized = path.startsWith("/") ? path : `/${path}`;
  let url = `${baseUrl()}${API_PATH}${normalized}`;
  if (query) {
    const params = new URLSearchParams();
    for (const [key, value] of Object.entries(query)) {
      const values = Array.isArray(value) ? value : [value];
      for (const item of values) {
        if (item !== undefined && item !== null) params.append(Array.isArray(value) ? `${key}[]` : key, String(item));
      }
    }
    const qs = params.toString();
    if (qs) url += `?${qs}`;
  }
  return url;
}

function parse(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

export async function request<T>(method: string, path: string, options: RequestOptions = {}): Promise<T> {
  const { query, body, headers, ...init } = options;
  const requestHeaders = new Headers(headers);
  requestHeaders.set("accept", "application/json");

  let payload: BodyInit | undefined;
  if (body !== undefined) {
    if (body instanceof FormData || body instanceof Blob || body instanceof URLSearchParams) {
      payload = body;
    } else {
      payload = JSON.stringify(body);
      requestHeaders.set("content-type", "application/json");
    }
  }

  const response = await fetch(apiUrl(path, query), { ...init, method, headers: requestHeaders, body: payload });
  const text = response.status === 204 ? "" : await response.text();
  const data = text ? parse(text) : null;

  if (!response.ok) {
    const exception = (data as ApiErrorBody | null)?.exception;
    if (exception && process.env.NODE_ENV !== "production") {
      // The Ruby exception behind a 500, so it shows up next to the failing request.
      console.error(`[GemStack API] ${method} ${path} → ${exception.class}: ${exception.message}\n  ${exception.backtrace.slice(0, 8).join("\n  ")}`);
    }
    throw new ApiError(response.status, data as ApiErrorBody | null, response.statusText || `HTTP ${response.status}`);
  }
  return data as T;
}

export const api = {
  get: <T>(path: string, options?: RequestOptions) => request<T>("GET", path, options),
  post: <T>(path: string, body?: unknown, options?: RequestOptions) => request<T>("POST", path, { ...options, body }),
  put: <T>(path: string, body?: unknown, options?: RequestOptions) => request<T>("PUT", path, { ...options, body }),
  patch: <T>(path: string, body?: unknown, options?: RequestOptions) => request<T>("PATCH", path, { ...options, body }),
  delete: <T = void>(path: string, options?: RequestOptions) => request<T>("DELETE", path, options),
};
