# US

A private, mobile-first messaging app for two people. Vanilla HTML/CSS/JS frontend, Supabase Postgres backend, hosted on Vercel. No framework, no build step.

## Layout

| Path | What it is |
| --- | --- |
| `src/` | The deployed site (`index.html`, `sw.js`, `manifest.json`, icons). Vercel project root. |
| `supabase/migrations/` | SQL history for the `lv_*` backend, copied from the migrations applied to production. |
| `supabase/functions/lv-push/` | Web Push edge function (rotated-key version, see status below). |
| `tests/frontend.test.js` | Playwright test against a mocked RPC backend (no real data touched). |

## How it works

- Custom auth (not Supabase Auth): bcrypt passwords, 60-day sessions stored as SHA-256 hashes, invite code stored hashed.
- Every table has Row Level Security enabled with no policies. All access goes through `SECURITY DEFINER` functions (`lv_*`) that check the session token. The browser only holds the public (publishable) key.
- Two-user cap is enforced by a database trigger.
- Sends carry a client id so retries cannot create duplicates.
- "Clear chat" is a soft delete (`deleted_at`), reversible with `lv_undo_clear`. Question-list overwrites and "reset asked questions" are archived first.

## Secrets (never committed)

- `VAPID_PRIVATE_KEY` lives only in Supabase Edge Function secrets.
- The service-role key and database password are never used in client code or this repo.
- `.env*`, `*.key`, `*.pem` and `vapid*.json` are git-ignored.

## Deploy and rollback

Frontend (Vercel, direct upload of `src/`): deploy to a preview, verify, then promote. Rollback is a Vercel rollback to the previous production deployment.

Database: migrations are additive. Pre-change copies of messages, media and the question list are in `bk_20261027_*` tables. Old function definitions are in the earlier migrations in this folder.

## Known limitations

- `src/index.html` was reconstructed from the production response and is not byte-verified against the original (about 12 bytes differ, likely invisible emoji characters). Behaviour is identical in tests. The previous Vercel deployment remains the rollback.
- Push key rotation is not finished: until the secret is added and the new `lv-push` is deployed, production uses the old key pair, and `src/index.html` still carries the old public key.
- Soft-deleted data is kept indefinitely; no purge has been approved.
