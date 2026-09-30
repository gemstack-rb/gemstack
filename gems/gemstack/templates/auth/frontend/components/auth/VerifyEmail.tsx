"use client";

import Link from "next/link";
import { useEffect, useRef } from "react";
import { errorMessage, useVerifyEmail } from "@/lib/auth";

// Confirms on load. Links in emails are opened with GET, so the page posts
// the token — a mail scanner prefetching the link can't use it up.
export function VerifyEmail({ token }: { token: string }) {
  const verify = useVerifyEmail();
  const started = useRef(false);

  useEffect(() => {
    if (started.current) return;
    started.current = true;
    verify.mutate(token);
  }, [token, verify]);

  if (verify.isSuccess) {
    return (
      <p>
        Your email address is confirmed. <Link href="/account">Continue</Link>
      </p>
    );
  }
  if (verify.isError) return <p className="form-error">{errorMessage(verify.error)}</p>;
  return <p className="muted">Confirming…</p>;
}
