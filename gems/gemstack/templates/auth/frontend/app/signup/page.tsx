"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { CredentialsForm } from "@/components/auth/CredentialsForm";
import { useSignup } from "@/lib/auth";

export default function SignupPage() {
  const router = useRouter();
  const signup = useSignup();

  return (
    <main className="page">
      <h1>Create an account</h1>
      <CredentialsForm
        submitLabel="Sign up"
        newPassword
        error={signup.error}
        pending={signup.isPending}
        onSubmit={(credentials) => signup.mutate(credentials, { onSuccess: () => router.push("/account") })}
      />
      <p className="muted">
        Already have an account? <Link href="/login">Log in</Link>
      </p>
    </main>
  );
}
