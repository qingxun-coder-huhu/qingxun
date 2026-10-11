# AGENTS.md

Guide for AI agents (and humans) working in the **Qingxun open-source (community) edition**.

> This is the standalone single-tenant edition: no login, no account system, the LLM key
> lives in a config file, and both script generation and real-device execution run in one
> Rails app. A fuller hosted edition is maintained separately; the file-by-file relationship
> between the two lives in [docs/OSS_SYNC_MAP.md](docs/OSS_SYNC_MAP.md) — **read it before
> porting any feature in or out**.

## Stack

- Ruby 3.2 / Rails 7.1 / PostgreSQL / Puma
- RSpec for tests; no linter configured
- Front end: server-rendered ERB + Bootstrap 5 (assets are plain files under `public/`)

## Commands

```bash
bundle install
bin/rails db:prepare           # create + migrate
bin/rails server               # http://localhost:3000
bundle exec rspec              # full suite
bundle exec rspec spec/services/device_runner_spec.rb:12   # single example
bin/rails zeitwerk:check       # eager-load sanity
```

Tests need PostgreSQL. Locally we use a unix socket:

```bash
DATABASE_HOST=/var/run/postgresql DATABASE_USERNAME=<user> RAILS_ENV=test bundle exec rspec
```

## Key entry points

- **Script generation / evaluation loop**: `app/services/auto_generate_service.rb`,
  `script_generation_service.rb`, `script_evaluation_service.rb`, `debug_session.rb`
  (runs generated code against a `FakeTelnetServer`), prompts under `app/services/prompts/`.
- **LLM access**: `app/services/llm_request_service.rb` + `llm_api_key.rb` +
  `qingxun_config.rb` (reads `config/qingxun.yml`).
- **Real-device execution**: `app/services/task_runner.rb` (fan-out over devices × scripts)
  and `app/services/device_runner.rb` (connect + run one script in `Qingxun::Sandbox`).
- **Script framework**: `lib/qingxun/` (`DeviceScript` base class, `Sandbox`, logging).
- **Device connectivity**: `lib/telnet_device.rb` (Telnet/SSH).

## Conventions

- Scripts inherit `Qingxun::DeviceScript` and implement `run(connection)`.
- Passwords / LLM keys never enter the database or logs in plaintext. Device credentials are
  encrypted with ActiveRecord::Encryption keys derived from `SECRET_KEY_BASE`.
- `config/qingxun.yml` is the single place for the LLM key; `.env` is for deployment secrets.
- Keep comments in Chinese to match the existing codebase.
- Preserve the behaviour documented in `docs/OSS_SYNC_MAP.md` when syncing from upstream.

## Do not reintroduce (hosted-only)

Accounts/login/activation, client identification codes & JWT, the `/admin` area, mailers,
API usage telemetry, per-request BYOK key handling, SEO/article pages, and the separate
local client app. See the "removed" list in `docs/OSS_SYNC_MAP.md`.
