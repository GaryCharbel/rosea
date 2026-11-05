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

## Data-integrity notes
- **Tickets are immutable once they leave `open`.** A paid/void ticket's lines are frozen by the `guard_child_only_when_open` trigger, and because `ticket_line.ticket_id` is `ON DELETE CASCADE`, that guard also makes a paid/void ticket **impossible to hard-delete** (the cascade delete of its lines is rejected). This is intentional — corrections are **void + re-ring**, never edit/delete. Never try to `DELETE` a closed ticket; `void_ticket` posts the reversing rows.

## Security advisors (the §6.4 security pass)
CI runs `db lint` + pgTAP — and pgTAP `013-rls` asserts RLS **and** a policy on every
public app table (the RLS-coverage gate). For the rest of the Supabase security advisor
checks (SECURITY DEFINER views, mutable function `search_path`, exposed auth data, etc.),
run against the linked project after a push:
```bash
npx supabase db advisors --level error   # or Dashboard → Advisors
```
Treat security-level advisor errors as merge/deploy blockers (Golden Rule #10).

## Cloud (owners' Supabase Pro project)
- Link: `npx supabase link --project-ref <ref>`
- Push migrations: `npx supabase db push` (see [release.md](release.md) — reviewed/merged only)
- Secrets live in the Supabase Dashboard / CI secrets — never in git.
