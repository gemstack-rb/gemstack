"use client";

import Link from "next/link";
import { useState, type FormEvent } from "react";
import { errorMessage, useForgotPassword } from "@/lib/auth";

export default function ForgotPasswordPage() {
  const [email, setEmail] = useState("");
  const forgot = useForgotPassword();

  function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    forgot.mutate(email);
  }

  if (forgot.isSuccess) {
    return (
      <main className="page">
        <h1>Check your email</h1>
        <p>If an account exists for {email}, we sent it a link to choose a new password.</p>
        <Link href="/login">Back to log in</Link>
      </main>
    );
  }

  const message = errorMessage(forgot.error);
  return (
    <main className="page">
      <h1>Reset your password</h1>
      <form className="form" onSubmit={handleSubmit}>
        <label className="field">
          Email
          <input type="email" autoComplete="email" required value={email} onChange={(e) => setEmail(e.target.value)} />
        </label>
        {message && (
          <p className="form-error" role="alert">
            {message}
          </p>
        )}
        <div className="actions">
          <button className="button" type="submit" disabled={forgot.isPending}>
            Send reset link
          </button>
        </div>
      </form>
    </main>
  );
}
