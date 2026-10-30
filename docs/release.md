# Rosea Platform — Release

Releases happen **only from reviewed, merged changes** (Golden Rule #1). Never push migrations or deploy from an unreviewed branch, and never commit to `main`.

## Database (Supabase cloud)
1. Migration lands on `main` via a reviewed PR (CI green: `db lint` + `db reset` + pgTAP).
2. Deploy: `npx supabase db push` against the linked cloud project.
3. Verify in Studio + run a smoke check (e.g. a test `pay_ticket` on staging data).

> Migrations are **forward-only** and must apply cleanly on a fresh DB in CI before merge.

## Web (Stage 3)
Deployed to **Cloudflare Pages** from `main` (a preview URL per branch, so `develop` is the staging link). Build/env in the Cloudflare Pages project. Next.js runs via the OpenNext adapter (static placeholder for now).

## POS
The Flutter POS releases from its own repo — **[`rosea-pos`](https://github.com/GaryCharbel/rosea-pos)** — where CI builds a Windows zip + an Android APK and uploads both to the MEGA folder. See that repo's `CLAUDE.md`.

## CI / repo secrets (names only — set in GitHub → Settings → Secrets → Actions)
This repo (`rosea`):
- `DISCORD_WEBHOOK` — Discord webhook for CI result notifications.

Never commit secret values; CI reads them from the encrypted store. (`rosea-pos` has its own `DISCORD_WEBHOOK` + `MEGA_USER` / `MEGA_PASS` / `MEGA_FOLDER`.)
