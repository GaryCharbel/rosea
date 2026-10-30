# Rosea Platform — Runbook

## Prerequisites
- **Docker** running (for the local Supabase stack)
- **Node** 20+ (the Supabase CLI is pinned as a dev dependency — no global install)

## Local development
```bash
npm install            # installs the pinned Supabase CLI
npx supabase start     # Postgres + Auth + Studio at http://localhost:54323
npx supabase db reset  # apply all migrations + run seeds (demo salon)
npx supabase test db   # pgTAP suite
npx supabase stop      # shut the stack down
```

## Migrations
```bash
npx supabase migration new <name>   # create a timestamped SQL file
# edit it under supabase/migrations/, then:
npx supabase db reset               # prove it applies cleanly from scratch
npx supabase db lint --level error  # lint
```
Migration **#1** creates the `private` schema + the `SECURITY DEFINER` role helpers + all enums (everything else depends on them).

## Auth hook (one-time, Dashboard)
After the `profiles` + `custom_access_token_hook` migration, enable the **Custom Access Token** hook in the Supabase Dashboard (Auth → Hooks) so the `user_role` claim is added to JWTs. Document the chosen project ref here when the cloud project is created.

## Cloud (owners' Supabase Pro project)
- Link: `npx supabase link --project-ref <ref>`
- Push migrations: `npx supabase db push` (see [release.md](release.md) — reviewed/merged only)
- Secrets live in the Supabase Dashboard / CI secrets — never in git.
