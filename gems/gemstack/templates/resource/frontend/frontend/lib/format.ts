// Display helpers shared by generated components.

/** Human-readable text for any API value. */
export function display(value: unknown): string {
  if (value === null || value === undefined || value === "") return "—";
  if (typeof value === "boolean") return value ? "Yes" : "No";
  if (typeof value === "object") return JSON.stringify(value);
  return String(value);
}

/** Field errors from an ApiError, keyed by attribute name. */
export type FieldErrors = Record<string, string[]>;
