"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { CredentialsForm } from "@/components/auth/CredentialsForm";
import { useLogin } from "@/lib/auth";

export default function LoginPage() {
  const router = useRouter();
  const login = useLogin();

  return (
    <main className="page">
      <h1>Log in</h1>
      <CredentialsForm
        submitLabel="Log in"
        error={login.error}
        pending={login.isPending}
        onSubmit={(credentials) => login.mutate(credentials, { onSuccess: () => router.push("/account") })}
      />
      <p className="muted">
        <Link href="/forgot-password">Forgot your password?</Link> · No account? <Link href="/signup">Sign up</Link>
      </p>
    </main>
  );
}
