# Rosea Platform — Release

Releases happen **only from reviewed, merged changes** (Golden Rule #1). Never push migrations or deploy from an unreviewed branch, and never commit to `main`.

## Database (Supabase cloud)
1. Migration lands on `main` via a reviewed PR (CI green: `db lint` + `db reset` + pgTAP).
2. Deploy: `npx supabase db push` against the linked cloud project.
3. Verify in Studio + run a smoke check (e.g. a test `pay_ticket` on staging data).

> Migrations are **forward-only** and must apply cleanly on a fresh DB in CI before merge.

## Web (Stage 3)
Deployed to Vercel from `main` (preview deploys per PR). Env/secrets in Vercel project settings.

## POS
The Flutter POS releases from its own repo — **[`rosea-pos`](https://github.com/GaryCharbel/rosea-pos)** — where CI builds a Windows zip + an Android APK and uploads both to the MEGA folder. See that repo's `CLAUDE.md`.
