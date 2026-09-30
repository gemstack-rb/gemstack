"use client";

import { useRouter } from "next/navigation";
import { useState, type FormEvent } from "react";
import { errorMessage, useResetPassword } from "@/lib/auth";

export function ResetPasswordForm({ token }: { token: string }) {
  const router = useRouter();
  const [password, setPassword] = useState("");
  const reset = useResetPassword();

  function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    reset.mutate({ token, password }, { onSuccess: () => router.push("/account") });
  }

  const message = errorMessage(reset.error);
  return (
    <form className="form" onSubmit={handleSubmit}>
      <label className="field">
        New password
        <input
          type="password"
          autoComplete="new-password"
          minLength={12}
          required
          value={password}
          onChange={(e) => setPassword(e.target.value)}
        />
      </label>
      {message && (
        <p className="form-error" role="alert">
          {message}
        </p>
      )}
      <div className="actions">
        <button className="button" type="submit" disabled={reset.isPending}>
          Save password
        </button>
      </div>
    </form>
  );
}
