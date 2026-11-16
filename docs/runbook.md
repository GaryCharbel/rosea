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

## Stage 1 owner demo + e2e commission check (Phase 5.3 sign-off)
The manual gate that closes Stage 1: ring up a multi-line, multi-performer, discounted,
split-paid ticket in the POS and confirm the backend recorded the right commission,
stock, and totals. Works against the local stack or the hosted project.

### Setup
1. Backend has the demo seed applied — local: `npx supabase db reset`; hosted: paste
   `supabase/seeds/10_demo.sql` into the SQL Editor. Gives 3 staff (Lea 40%/10%,
   Maya 35%/—, Sam 30%/8%) + catalog.
2. An **owner** (or staff) login exists — local: `00_auth.sql` seeds `owner@rosea.local`
   / `rosea1234`; hosted: create the user in Auth → Users, then promote (see the
   owner-bootstrap SQL). The POS blocks non-staff/owner at the shell.
3. POS config points at the backend: `env/local.json` with the project URL + publishable
   key. Run: `flutter run -d windows --dart-define-from-file=env/local.json`.

### The demo ticket (expected numbers)
Sign in → **Choose performer: Lea** → Open checkout, then:
| Line | Performer | Price | Discount | Line total | Commission |
|---|---|---|---|---|---|
| Women's Cut | Lea (40%) | 45.00 | — | 45.00 | **18.00** |
| Full Color | Maya (35%) | 90.00 | 10.00 | 80.00 | **28.00** |
| Shampoo 250ml | Lea (10% product) | 18.00 | — | 18.00 | **1.80** |

(Change the performer chip to Maya on the Full Color line; add the 10.00 line discount.)
Subtotal **153.00**, discount **10.00**, total **143.00**. Pay split: **Cash 100.00 + Card
43.00** → Take payment → receipt prints with a ticket #.

### Verify in SQL (swap in the ticket id from the receipt / `select id,ticket_no from ticket order by closed_at desc limit 1`)
```sql
-- commission per staff: expect Lea 19.80, Maya 28.00
select s.name, sum(ce.amount) as commission
from public.commission_entry ce join public.staff s on s.id = ce.staff_id
where ce.ticket_id = '<ticket-id>' group by s.name order by s.name;

-- stock decremented: Shampoo 40 -> 39
select name, stock_quantity from public.product where sku = 'SH-250';

-- totals reconcile + paid
select status, subtotal, discount_total, total from public.ticket where id = '<ticket-id>';
-- expect: paid / 153.00 / 10.00 / 143.00

-- payments applied sum to the total
select coalesce(sum(amount),0) from public.payment where ticket_id = '<ticket-id>'; -- 143.00
```

### Void re-check (optional but proves reversal)
Owner → void the ticket, then re-run the queries: commission per staff nets to **0**,
Shampoo stock is back to **40**, ticket `status = 'void'`. That's the full round-trip.
