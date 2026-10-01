# Contributing to GemStack

Thanks for helping. Bug reports, fixes, docs, and features are all welcome.

- **Found a bug?** [Open an issue](https://github.com/gemstack-rb/gemstack/issues/new/choose) with the
  steps to reproduce it.
- **Want to add a feature or make a large change?** Open an issue first, so we can agree on the approach
  before you put time into it.
- **Found a security vulnerability?** Don't open a public issue. See [SECURITY.md](SECURITY.md).

## Setup

You need **Ruby 3.3 or newer** (installed with rbenv, rvm, asdf, mise, chruby, or a package manager) and
**Node.js 20.9+** (Node is only needed for `script/e2e`).

```bash
git clone https://github.com/<you>/gemstack.git   # your fork
cd gemstack
bundle install
bundle exec rake                                  # every test suite + RuboCop — should pass before you start
```

`bin/gemstack` and `bin/gsk` run the CLI from your checkout, so either launcher can create a real app
with your changes.

## How the code is organised

| Path | What it is |
|---|---|
| `gems/gemstack/lib/gemstack/<module>/` | The framework, split into modules: `core`, `cache`, `schema`, `http`, `db`, `jobs`, `mail`, `storage`, `contract`, `dev`, `cli` |
| `gems/gemstack/templates/` | The files `gemstack new` and the generators create (part of `cli`) |
| `gems/gemstack-auth/`, `gems/gemstack-realtime/` | The two optional gems |
| `gems/gemstack-cli/` | The `gemstack` and `gsk` executable launchers |
| `gems/gemstack/test/<module>/`, `gems/*/test/` | One test suite per module |
| `docs/` | The user documentation |
| [ARCHITECTURE.md](ARCHITECTURE.md) | How the modules fit together, and the rules below |

Modules may only use modules that come **before** them:
core → cache → schema → http → db → jobs → mail → storage → realtime → auth → contract → dev → cli.
`core` uses only the Ruby standard library, and `require "gemstack"` must not load `db`, `jobs`, `mail`,
or `storage`. `test/app/architecture_test.rb` enforces these rules. Please discuss any new runtime
dependency in an issue first.

## Tests

**Every change to the code needs tests.** A pull request that changes a module's code without changing
that module's tests fails the *Changed code has tests* check. For a change that really needs none (a
pure refactor, a comment), a maintainer can add the `no-tests-needed` label.

### Where tests go

Tests use [Minitest](https://github.com/minitest/minitest). Each module has its own suite and
`test_helper.rb`:

| You changed | Add tests in | Run with |
|---|---|---|
| `lib/gemstack/http/…` | `gems/gemstack/test/http/` | `bundle exec rake test:http` |
| `lib/gemstack/db/…` | `gems/gemstack/test/db/` | `bundle exec rake test:db` |
| `lib/gemstack/cli/…` or `templates/…` | `gems/gemstack/test/cli/` | `bundle exec rake test:cli` |
| `lib/gemstack/<module>/…` | `gems/gemstack/test/<module>/` | `bundle exec rake test:<module>` |
| `lib/gemstack/settings.rb`, `inflector.rb`, `logger.rb`, … | `gems/gemstack/test/core/` | `bundle exec rake test:core` |
| `lib/gemstack/application.rb`, `reloader.rb`, `testing.rb` | `gems/gemstack/test/app/` | `bundle exec rake test:app` |
| `gems/gemstack-auth/…` | `gems/gemstack-auth/test/` | `bundle exec rake test:auth` |
| `gems/gemstack-realtime/…` | `gems/gemstack-realtime/test/` | `bundle exec rake test:realtime` |

`script/changes` prints the suites that your branch touches.

### Writing a test

Add your test to the test file that covers the code you changed, or start a new file:

```bash
bundle exec rake "test:new[http,rate_limiting]"
# Created gems/gemstack/test/http/rate_limiting_test.rb
```

The new file has the right helpers for its module and a placeholder test that fails until you replace
it. Here is an HTTP test, for example:

```ruby
# frozen_string_literal: true

require "test_helper"

class RateLimitingTest < Minitest::Test
  include Rack::Test::Methods
  include HTTPTestHelpers

  class PingController < GemStack::HTTP::Controller
    def show = render({ pong: true })
  end

  def app
    router = GemStack::HTTP::Router.new(prefix: "/api", resolver: ->(_) { PingController }).draw do
      get "/ping", to: "ping#show"
    end
    GemStack::HTTP::App.new(config: build_config, router: router)
  end

  def test_answers_until_the_limit_then_returns_429
    3.times { get "/api/ping" }

    assert_equal 200, last_response.status
    get "/api/ping"

    assert_equal 429, last_response.status
    assert_equal "rate_limited", json(last_response)["error"]["code"]
  end
end
```

Good tests here:

- **Test behaviour, not implementation.** Test what a user of GemStack would see: a response, a
  generated file, a return value, an error.
- **One behaviour per test**, with a name that says what it is: `test_rejects_an_expired_token`.
- **Cover the edge cases and the error path**, not only the happy path. A bug fix needs a test that
  fails without the fix.
- **Keep tests self-contained.** Use temp directories (`Dir.mktmpdir`) instead of the repo, make no
  network calls, and don't depend on the order tests run in.
- **CLI and generator tests** generate into a temp directory and check the files. See
  `gems/gemstack/test/cli/`.
- **Keep test data fake.** Use `ada@example.com`, never real people, customers, or credentials.

### Running tests

```bash
bundle exec rake test:changed                    # the suites your branch touches
bundle exec rake test:http                       # one suite
bundle exec rake test:http TEST=gems/gemstack/test/http/router_test.rb     # one file
bundle exec rake test:http TESTOPTS="-n/rate_limit/"                      # tests matching a name
bundle exec rake                                 # everything + RuboCop (what CI runs)
```

The `db`, `jobs`, and `auth` suites need a database. Without one, those tests are skipped.
`bundle exec rake test:databases` always runs them on SQLite. To run them on PostgreSQL and MySQL too,
start the servers with Docker:

```bash
docker run -d --name gemstack-pg -e POSTGRES_PASSWORD=postgres -p 5432:5432 postgres:17
docker run -d --name gemstack-mysql -e MYSQL_ROOT_PASSWORD=root -p 3306:3306 mysql:8.4
export GEMSTACK_TEST_DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/gemstack_test
export GEMSTACK_TEST_MYSQL_URL=mysql2://root:root@127.0.0.1:3306/gemstack_test
bundle exec rake test:databases
```

For changes to generators, templates, or the Next.js side, also run `script/e2e`. It generates a
full app and runs its tests, the TypeScript check, and `next build`. `script/ruby-matrix` runs the
suite on Ruby 3.3, 3.4, and 4.0 in Docker.

## Style

- **Match the code around you**: its naming, comment density, and idioms.
- **Run `bundle exec rubocop`** (it's part of `bundle exec rake`). `bundle exec rubocop -a` fixes most
  offences.
- **Keep changes focused.** A pull request should do one thing. Avoid unrelated reformatting.

## Docs and changelog

- **Update `docs/`** if users will see your change: a new option, a behaviour change, or a new command.
- **Add a line to `CHANGELOG.md`** under `## Unreleased` (create the heading if it's missing).
  Maintainers turn it into the version heading when releasing.

## Pull requests

1. Fork the repository and create a branch from `main`.
2. Make your change with its tests. Check that `bundle exec rake` passes.
3. Open a pull request and fill in the template.

On every pull request, CI runs:

| Check | What it does |
|---|---|
| **Ruby 3.3 / 3.4 / 4.0** | All suites, the database suites on SQLite, PostgreSQL, and MySQL, and RuboCop |
| **End to end** | `script/e2e`: a generated app's tests, TypeScript, and `next build` |
| **Changed code has tests** | `script/changes --check` |

For first-time contributors, a maintainer approves the CI run before it starts. A maintainer then
reviews the pull request, and merges it once every check is green.

**Never commit secrets** such as API keys, tokens, passwords, or `.env` files, or real personal or
customer data. That applies to tests and fixtures too. Everything in a pull request is public, and it
stays public even if it's removed later.

## License

GemStack is released under the [MIT License](LICENSE.txt). By contributing, you agree that your
contributions are released under the same license.
