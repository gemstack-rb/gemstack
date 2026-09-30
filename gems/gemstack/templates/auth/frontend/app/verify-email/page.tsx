import { VerifyEmail } from "@/components/auth/VerifyEmail";

export default async function VerifyEmailPage({ searchParams }: { searchParams: Promise<{ token?: string }> }) {
  const { token } = await searchParams;
  return (
    <main className="page">
      <h1>Confirm your email</h1>
      {token ? <VerifyEmail token={token} /> : <p className="form-error">This link is missing its token.</p>}
    </main>
  );
}
