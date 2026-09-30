# Authentication

New apps have **no** authentication until you add it:

```bash
gemstack add auth
gemstack db:migrate
gemstack dev            # open http://localhost:3000/signup
```

This adds the `gemstack-auth` gem, switches on `require "gemstack/mail"` (and
`gemstack/jobs`, for sending emails) in `config/app.rb`, and generates code you own:

| Generated | What it is |
| --- | --- |
| `db/migrations/*_create_auth_tables.rb` | `users`, `sessions`, `auth_tokens` (+ the jobs table, for emails) |
| `app/models/user.rb`, `auth_token.rb` | `User` includes `GemStack::Auth::User` |
| `app/serializers/user_serializer.rb` … | what the API shows (never the password digest) |
| `app/controllers/{registrations,sessions,password_resets,email_verifications,api_tokens}_controller.rb` | the endpoints below |
| `app/mailers/auth_mailer.rb` + templates | password reset and email confirmation emails |
| `test/controllers/auth_test.rb` | every flow, end to end |
| `frontend/lib/auth.ts` | `useCurrentUser`, `useLogin`, `useSignup`, `useLogout`, … |
| `frontend/app/{login,signup,forgot-password,reset-password,verify-email,account}/` | Next.js pages |

`ApplicationController` gains `include GemStack::Auth::Controller`.

## Endpoints

| Route | Action |
| --- | --- |
| `POST /api/auth/signup` | create account, sign in, send confirmation email (201) |
| `POST /api/auth/login` | sign in (401 `invalid_credentials` otherwise) |
| `GET /api/auth/me` | the current user (401 `unauthenticated` when signed out) |
| `DELETE /api/auth/logout` | end this session |
| `POST /api/auth/password/forgot` | email a reset link — always 202 |
| `POST /api/auth/password/reset` | `{ token, password }`: new password, ends all sessions, signs in |
| `POST /api/auth/email/resend` · `POST /api/auth/email/verify` | email confirmation |
| `GET/POST /api/auth/tokens` · `DELETE /api/auth/tokens/:id` | personal API tokens |

## Protecting controllers

```ruby
class OrdersController < ApplicationController
  before :require_login                     # 401 for anonymous requests

  def index = render(paginate(current_user.orders_dataset.order(:id)))
end
```

Helpers: `current_user`, `signed_in?`, `require_login`, `sign_in(user)`,
`sign_out`, `current_session`, `authenticated_by` (`:session` or `:token`).

## How it works

**Browsers** get a random session token in an **HttpOnly** cookie
(`SameSite=Lax`; in production `Secure` with the `__Host-` prefix). The
database stores only its SHA-256 digest (`sessions`), so a database leak
doesn't hand out sessions, and sessions can be listed and revoked — a
password reset really ends them. Sessions last 30 days and slide on use. The
Next.js frontend and the API share an origin, so there is nothing to
configure and no token in JavaScript to steal.

**Scripts and other services** send `Authorization: Bearer gs_…` with a
personal API token from `/account`. Tokens are also stored as digests; they
can't create or revoke other tokens.

**Passwords** are hashed with **Argon2id** (t=2, 32 MiB — about 35 ms)
through the `argon2` gem. Hashes from other systems in bcrypt format verify
if you add `gem "bcrypt"` and are upgraded on the next login. Passwords must be
12–128 characters; there are no composition rules (NIST SP 800-63B) (D-049).

**Login** gives the same answer for an unknown email and a wrong password,
and spends the same time on both (a dummy hash for unknown emails).
**Forgot password** always answers 202. Reset and verification links are
single use, expire (1 hour / 3 days), and are consumed atomically (D-050).

**Cross-site request forgery:** state-changing requests from other sites are
refused (403 `cross_site_request`) using the `Sec-Fetch-Site` / `Origin`
headers every browser sends, on top of `SameSite=Lax`. There are no CSRF
tokens to thread through forms. Allow another origin of yours with
`config.auth.trusted_origins = ["https://admin.example.com"]` (D-051).

**Rate limits** (per IP and per email address) protect signup, login and the
email endpoints: `rate_limit to: 10, within: 300, only: :create`. They count in
`GemStack.cache` — use the Redis store with more than one server. Over the
limit: 429 with `Retry-After`.

## Configuration

```ruby
GemStack.configure do |config|
  config.auth.session_ttl = 14 * 24 * 3600      # seconds (default 30 days, sliding)
  config.auth.password_min_length = 12
  config.auth.trusted_origins = []
  config.auth.app_url = "https://shop.example"  # links in emails (default APP_URL or http://localhost:3000)
  config.auth.argon2_m_cost = 16                 # 64 MiB, if your servers can afford it
end
```

Delete expired rows daily, e.g. from a job: `GemStack::Auth.cleanup!`.

## Testing

```ruby
sign_in_as(user)                                  # later requests carry the session cookie
get_json "/api/orders", {}, bearer_headers(user)  # or an API token
assert_emails(1) { post_json "/api/auth/password/forgot", { email: user.email } }
```

## Server Components

Browser requests carry the cookie automatically. A Server Component that calls
the API must forward it:

```tsx
import { cookies } from "next/headers";
const user = await sessions.get({ headers: { cookie: (await cookies()).toString() } });
```

## Existing users table

`gemstack add auth` refuses to overwrite an existing `app/models/user.rb`.
Add `include GemStack::Auth::User` to your model (it needs `email`,
`password_digest` and, for verification, `email_verified_at`), create the
`sessions` and `auth_tokens` tables from the generated migration, and copy the
controllers you need from the GemStack templates.
