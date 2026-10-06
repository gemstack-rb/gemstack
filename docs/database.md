# Databases

GemStack works with **SQLite**, **PostgreSQL** and **MySQL** through
[Sequel](https://sequel.jeremyevans.net).

```bash
gemstack new shop                        # SQLite — nothing to install or run
gemstack new shop --database=postgresql
gemstack new shop --database=mysql2      # or trilogy (MySQL driver without libmysqlclient)
gemstack new shop --skip-database        # an API without a database
```

`gemstack new` writes `config/database.yml`, adds the driver gem (`sqlite3`,
`pg`, `mysql2` or `trilogy`) to the Gemfile and runs `gemstack db:create`.

## config/database.yml

The same format as Rails', ERB included:

```yaml
default: &default
  adapter: postgresql
  pool: <%= ENV.fetch("GEMSTACK_MAX_THREADS", 5) %>
  host: localhost
  username: shop
  password: <%= ENV["DATABASE_PASSWORD"] %>

development:
  <<: *default
  database: shop_development

test:
  <<: *default
  database: shop_test

production:
  <<: *default
  database: shop_production
```

| Key | |
| --- | --- |
| `adapter` | `sqlite3`, `postgresql`, `mysql2` or `trilogy` (`postgres`, `mysql`, `sqlite` also work) |
| `database` | the database name; for SQLite the file, relative to the app (`db/development.sqlite3`) or absolute |
| `host`, `port`, `username`, `password` | the server |
| `pool` | connections per process (default: `GEMSTACK_MAX_THREADS`, one per Puma thread) |
| `url` | a full URL instead of the keys above; other keys still override its parts |
| anything else | passed to the driver, e.g. `sslmode: require` for PostgreSQL |

### Where settings come from

First match wins:

1. `config.db.url` in `config/app.rb` or `config/environments/*.rb`
2. `DATABASE_URL` — in the test environment `TEST_DATABASE_URL`, never
   `DATABASE_URL`, so a development database from `.env` can't be wiped by tests
3. `config/database.yml`, the section for the current environment (`GEMSTACK_ENV`)
4. apps without `database.yml`: PostgreSQL on this machine, `<app>_<env>`

Hosting platforms set `DATABASE_URL`, so production usually needs nothing in
`database.yml` beyond the adapter. URL forms:

```text
postgres://user:password@host:5432/shop_production?sslmode=require
mysql2://user:password@host:3306/shop_production     (or trilogy://…)
sqlite3:db/production.sqlite3                        (relative to the app)
sqlite3:///var/data/shop.sqlite3                     (absolute)
```

`gemstack doctor` shows which database the app uses and where the setting
came from.

## What differs between databases

Models, migrations, validations, serializers, the generators, auth, storage
and tests work the same on all three. Differences are in what the database
itself can do:

| | SQLite | PostgreSQL | MySQL 8 |
| --- | --- | --- | --- |
| Setup | none (a file) | a server | a server |
| Background jobs | ✓ database queue, polls every 1 s | ✓ `SKIP LOCKED`, instant `NOTIFY` wake-up | ✓ `SKIP LOCKED`, polls every 1 s |
| Realtime across processes | needs Redis (`config.realtime.broker = :redis`) | ✓ built in (`LISTEN/NOTIFY`) | needs Redis |
| Constraint errors → 422 field errors | unique, not null; foreign keys → 409 | unique, not null, foreign keys | unique¹, not null, foreign keys |
| JSON columns | stored as text, (de)serialized | `jsonb` | `json` |
| Statement timeout (`config.db.statement_timeout`) | — | `statement_timeout` | `max_execution_time` (SELECT) |
| Concurrent writers | one at a time (WAL mode, 5 s busy timeout) | many | many |

¹ MySQL names the index, not the column; the generators' `unique: true`
columns map to the field, composite indexes become a 409 conflict.

### Migrations are portable

Migrations may use PostgreSQL's type names, as the generators do, and still
run on MySQL and SQLite:

| In a migration | PostgreSQL | MySQL | SQLite |
| --- | --- | --- | --- |
| `column :created_at, :timestamptz` | `timestamptz` | `datetime(6)` | `timestamp` |
| `column :data, :jsonb` | `jsonb` | `json` | `json` (text) |
| `column :token, :uuid` | `uuid` | `char(36)` | `varchar(36)` |
| `column :ip, :inet` | `inet` | `varchar(45)` | `varchar(45)` |

Times are stored in UTC on every adapter. Everything else in Sequel's schema
DSL is unchanged — use `database_type` in a migration for anything
adapter-specific.

## Production: use PostgreSQL

SQLite is the development default because it needs nothing installed. For
production, **use PostgreSQL**: concurrent writers, several servers, realtime
and job wake-ups across processes through `LISTEN/NOTIFY`, and managed hosting
everywhere.

Where the production connection comes from:

1. **`DATABASE_URL`** — `postgres://user:password@host:5432/shop_production`. It
   overrides `config/database.yml`; hosting platforms set it, and
   `gemstack generate deploy` passes it to every role.
2. Otherwise the `production:` section of `config/database.yml`.

An app created with SQLite switches with `gem "pg"` in the Gemfile and
`DATABASE_URL` in production (or `gemstack new --database=postgresql` from the
start). `gemstack doctor --production` shows which connection is used and
warns about SQLite.

SQLite in production suits a single server only: keep the file on a persistent
volume (the Kamal config mounts one), back it up, and run every process on
that host.

## Switching databases

Change `adapter` (and the connection keys) in `config/database.yml`, replace
the driver gem in the Gemfile, then `bundle install`, `gemstack db:create` and
`gemstack db:migrate`. Data isn't converted; export and import it with your
database's tools.

## Commands

```bash
gemstack db:create        # create the database (SQLite: the file)
gemstack db:migrate       # apply pending migrations   (--target VERSION)
gemstack db:rollback      # revert the last migration   (--steps N)
gemstack db:status        # applied / pending
gemstack db:seed          # load db/seeds.rb
gemstack db:setup         # create + migrate + seed
gemstack db:reset         # drop + setup (development/test only)
gemstack db:drop          # refused in production unless GEMSTACK_ALLOW_DB_DROP=1
```

Models, validations and queries: [models](models.md).
