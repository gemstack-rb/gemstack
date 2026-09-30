"use client";

import { useState, type FormEvent } from "react";
import { errorMessage, type Credentials } from "@/lib/auth";

export function CredentialsForm({
  submitLabel,
  newPassword = false,
  error,
  pending,
  onSubmit,
}: {
  submitLabel: string;
  newPassword?: boolean;
  error: unknown;
  pending: boolean;
  onSubmit: (credentials: Credentials) => void;
}) {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");

  function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    onSubmit({ email, password });
  }

  const message = errorMessage(error);
  return (
    <form className="form" onSubmit={handleSubmit}>
      <label className="field">
        Email
        <input type="email" autoComplete="email" required value={email} onChange={(e) => setEmail(e.target.value)} />
      </label>
      <label className="field">
        Password
        <input
          type="password"
          autoComplete={newPassword ? "new-password" : "current-password"}
          minLength={newPassword ? 12 : undefined}
          required
          value={password}
          onChange={(e) => setPassword(e.target.value)}
        />
        {newPassword && <small className="muted">At least 12 characters. A few random words work well.</small>}
      </label>
      {message && (
        <p className="form-error" role="alert">
          {message}
        </p>
      )}
      <div className="actions">
        <button className="button" type="submit" disabled={pending}>
          {pending ? "Please wait…" : submitLabel}
        </button>
      </div>
    </form>
  );
}
