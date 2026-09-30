import { ResetPasswordForm } from "@/components/auth/ResetPasswordForm";

export default async function ResetPasswordPage({ searchParams }: { searchParams: Promise<{ token?: string }> }) {
  const { token } = await searchParams;
  return (
    <main className="page">
      <h1>Choose a new password</h1>
      {token ? <ResetPasswordForm token={token} /> : <p className="form-error">This link is missing its token.</p>}
    </main>
  );
}
