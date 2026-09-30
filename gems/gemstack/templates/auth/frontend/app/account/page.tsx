"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState, type FormEvent } from "react";
import {
  errorMessage,
  useApiTokens,
  useCreateApiToken,
  useCurrentUser,
  useLogout,
  useResendVerification,
  useRevokeApiToken,
} from "@/lib/auth";

export default function AccountPage() {
  const router = useRouter();
  const { data: user, isPending } = useCurrentUser();
  const logout = useLogout();
  const resend = useResendVerification();

  if (isPending) return <main className="page muted">Loading…</main>;
  if (!user) {
    return (
      <main className="page">
        <h1>Account</h1>
        <p>
          You are signed out. <Link href="/login">Log in</Link> or <Link href="/signup">sign up</Link>.
        </p>
      </main>
    );
  }

  return (
    <main className="page">
      <div className="page-header">
        <h1>Account</h1>
        <button className="button" onClick={() => logout.mutate(undefined, { onSuccess: () => router.push("/login") })}>
          Log out
        </button>
      </div>
      <dl className="card">
        <dt>Email</dt>
        <dd>
          {user.email}{" "}
          {user.email_verified_at ? (
            <span className="muted">(confirmed)</span>
          ) : (
            <button className="button" disabled={resend.isPending || resend.isSuccess} onClick={() => resend.mutate()}>
              {resend.isSuccess ? "Email sent" : "Resend confirmation email"}
            </button>
          )}
        </dd>
        <dt>Member since</dt>
        <dd>{new Date(user.created_at).toLocaleDateString()}</dd>
      </dl>
      <ApiTokens />
    </main>
  );
}

function ApiTokens() {
  const tokens = useApiTokens();
  const create = useCreateApiToken();
  const revoke = useRevokeApiToken();
  const [name, setName] = useState("");

  function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    create.mutate(name, { onSuccess: () => setName("") });
  }

  return (
    <section>
      <h2>API tokens</h2>
      <p className="muted">
        For scripts and other services: send <code>Authorization: Bearer &lt;token&gt;</code>.
      </p>
      {create.data && (
        <p className="status status-ok">
          <span className="dot" />
          Copy your new token now — it won&apos;t be shown again: <code>{create.data.token}</code>
        </p>
      )}
      <form className="form" onSubmit={handleSubmit}>
        <label className="field">
          Name
          <input required maxLength={100} value={name} onChange={(e) => setName(e.target.value)} placeholder="CI" />
        </label>
        {create.error && <p className="form-error">{errorMessage(create.error)}</p>}
        <div className="actions">
          <button className="button" type="submit" disabled={create.isPending}>
            Create token
          </button>
        </div>
      </form>
      <table className="table">
        <tbody>
          {tokens.data?.map((token) => (
            <tr key={token.id}>
              <td>{token.name}</td>
              <td className="muted">
                {token.last_used_at ? `used ${new Date(token.last_used_at).toLocaleString()}` : "never used"}
              </td>
              <td>
                <button className="button button-danger" onClick={() => revoke.mutate(token.id)}>
                  Revoke
                </button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  );
}
