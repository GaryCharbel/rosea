# Rosea — Project Rules & Regulations for Claude

Rosea is a beauty-salon platform (online booking website + desktop POS + backoffice dashboard) on a single Supabase backend. Built for the owners at no charge; they pay only running costs (Supabase Pro ~$25/mo + a domain ~$15/yr). Owner & author: **Gary Charbel El Hadchity** (write his name in full — never abbreviate).

---

## 🔒 Golden rules (non-negotiable)

1. **RULE #1 — Nothing gets merged before a thorough review.** No branch merges into `develop` or `main` until it has been fully reviewed *and* runtime-tested. Reviewing means reading the diff for correctness, security, and convention adherence — not just "it compiles."
2. **Never commit to `main`.** `main` is protected. All work happens on branches. Never `git commit` or `git push` directly to `main` (and treat `develop`/the integration branch the same way — go through a reviewed PR).
3. **No AI/Claude attribution anywhere in git** — not in commit messages, branch names, or PR titles/bodies. **Gary pushes and opens PRs himself**; do not push or open PRs on his behalf unless he explicitly asks.
4. **Never force-push** a branch that has been pushed/shared. Resolve divergence by merging `develop`/`main` locally, not by rebasing + force-pushing.
5. **Review AND runtime-test every commit.** Actually run the thing and observe correct behavior before claiming done — not just a successful build.
6. **Pair backend + frontend per feature.** Build a feature's BE and its FE together and test the pair end-to-end before starting the next feature. No backend-only pileups.
7. **Every error message is actionable** (backend and frontend): say what happened *and* what to do about it. Never a generic "unexpected error."
8. **Anything that can be automated, should be automated.** Prefer a script/hook/CI job over a manual step. This covers: running tests + lint on every commit/PR, DB migrations and type generation, the demo seed, builds/releases of the Windows POS, env syncing, and any repeatable chore. If you find yourself about to tell Gary to "just run these steps by hand," automate them instead and document the one command.
9. **CI gate on every PR and every push to a PR.** CI must (a) build the app and (b) run the full unit-test suite — on every push. **A PR does not merge if the build fails or any test fails** (this is part of Rule #1's "thorough review"). **Write unit tests for every piece of logic** as you build it — untested logic is not done. No disabling/skipping tests to get a merge through.
10. **Security & data confidentiality are a priority — treat them as first-class, not an afterthought.** The salon holds client PII (names, phones, emails, visit history) and financial data. Protect it by default; every PR review includes a security pass. See the Security section below — those rules are non-negotiable.
11. **Speed, reliability, and data correctness come first.** This is a POS handling money and commissions — it must be fast, it must not fall over mid-sale, and the numbers must always be exactly right. When trading off, correctness > reliability > speed, and all three beat extra features. See "Performance, reliability & data integrity" below.

---

## Repository structure (hybrid — two repos)

Rosea is split into **two git repos**, grouped by toolchain + release cadence:

1. **`rosea` (THIS repo) — the platform.** Supabase backend/infra + the web apps (one TS ecosystem; deploys to Supabase + Cloudflare Pages):
   ```
   rosea/
     CLAUDE.md  docs/
     supabase/            # migrations, RLS, pay_ticket & edge functions, seed, config.toml  (BE + infra)
     web/                 # Next.js — booking site + backoffice  (Stage 2–3; scaffolded now, built later)
     packages/types/      # TS types generated from the schema (single source of truth)
     .github/workflows/   # path-filtered CI: supabase (db lint + pgTAP) | web (build + test)
   ```
2. **`rosea-pos` (separate repo) — the Flutter desktop POS.** Dart/Flutter toolchain, ships as its own Windows binary on its own cadence. Its own CI (`flutter build` + `flutter test`).

**Cross-repo contract:** the Supabase schema is the single source of truth. When it changes in `rosea`, regenerate the POS's Dart models and update them in `rosea-pos` via a reviewed PR. **Automate that generation** (Rule #8) so the contract never drifts.

Both repos follow **this same rulebook** — keep `CLAUDE.md` in sync between them. The design spec + implementation plan live in **`rosea/docs/`** (shared reference for both).

## Scope right now: Foundation + Stage 1

Build only these now. Leave clean, explicit hooks for later stages but do **not** implement them.

- **Foundation:** Supabase schema baseline, Auth (roles: `owner` / `staff` / `client`), RLS, `salon_settings`.
- **Stage 1 — POS core:** catalog (services, products, categories), staff + commission rates, tickets with per-line performer, split payments, tips, printed receipt, and the commission engine. Flutter desktop POS for all of this.
- **Deferred (hooks only):** booking website, offers/promo/dashboard, gift cards, memberships, loyalty, reports.

The authoritative design spec and implementation plan live in **`docs/`** — read them before building.

---

## Product-logic invariants (must never be violated)

- **Performer-per-line:** every ticket line is credited to the staff member who performed/sold it; that person earns the commission on that line.
- **Commission = rate × POST-discount amount**, counted **only on paid tickets**. Services use the staff member's rate; retail products earn only if the product is `commission_eligible` (own product rate). Tips are tracked per staff, **separate** from commission.
- **Payments:** manual method (cash / card / other), splits allowed, no card-terminal integration.
- **Light resilience only:** cache the catalog locally and retry sends on a brief blip. **No full offline selling.** Be explicit about what works offline vs. what blocks.
- **Single salon** — don't build multi-location, but don't hard-code assumptions that make it impossible later.

---

## Performance, reliability & data integrity (top priority)

Order of priority when trading off: **correctness → reliability → speed → features.**

- **Data correctness is sacred.** Money and commissions must always be exact. Enforce integrity in the database, not just the app: `NOT NULL`, `CHECK` constraints (non-negative amounts, valid statuses), foreign keys, and the rule that a ticket's `total` reconciles to its lines/payments. Money is `numeric(10,2)` with one defined rounding rule — never floats for money.
- **Atomic, idempotent writes.** All money-affecting writes (`pay_ticket`, voids/refunds) happen in a single transaction with row locking (`SELECT … FOR UPDATE`) and are idempotent so a retry can never double-charge or double-count commission. Partial writes must roll back fully.
- **Reliability at the counter.** Checkout must not fail on a WiFi blip: cache the catalog, queue the pay call, retry with backoff (light resilience). Surface clear state ("saved / syncing / retrying"), never silently lose a sale. Validate before writing so bad data can't be committed.
- **Speed.** Checkout and catalog must feel instant. Index for the real queries (e.g., `commission_entry(staff_id, earned_at)`, ticket lookups); keep RLS policies cheap (wrap helpers in `(select …)`); paginate lists. Set a target (e.g., add-line and pay feel sub-100ms on the UI).
- **Algorithmic efficiency — always check the big-O, and zero N+1.** For every hot path, reason about its time/space complexity and pick the best achievable one; don't ship an O(n²) where an O(n) or O(n log n) exists. **No N+1 query patterns, ever** — fetch sets in one round-trip (join, `in (…)`, batched/`select` with embedded relations), never a query per row in a loop. Every PR review explicitly checks for N+1 and complexity regressions; add query-count/`explain` checks where it matters.
- **Prove it.** Correctness is covered by tests (commission math, reconciliation, idempotency) that run in CI (Rules #8–#9). Reliability is tested by simulating offline/retry. Don't claim fast/correct without measuring.

## Security & data confidentiality (non-negotiable)

- **RLS on every table, always on.** No table is ever exposed without a policy. Never disable RLS to "make something work" — fix the policy. Default-deny: if no policy grants access, access is denied.
- **Least privilege.** Each role (`owner`/`staff`/`client`) gets only what it needs. Staff see only their own `commission_entry`; clients never touch POS/financial data; a client can only read/write their own records.
- **The `service_role` key never ships in a client app** (Flutter POS or the web frontends). It lives only in trusted server contexts (Edge Functions / CI secrets). Clients use the anon key + the user's JWT, gated by RLS.
- **Secrets never get committed.** No keys, tokens, DB URLs, or `.env` files in git. Use env management + CI secrets; provide `.env.example` with blank placeholders. If a secret ever lands in a commit, rotate it.
- **PII protection.** Never log client PII (names, phones, emails) or put it in URLs/query strings. Minimize what's collected and returned — select only the columns a screen needs. Redact PII in error reports/telemetry.
- **Everything over TLS** (Supabase enforces HTTPS/SSL). Don't build any plaintext channel.
- **Validate & parameterize.** All input validated server-side; never build SQL by string-concatenation — use parameters/`$1` bindings. `SECURITY DEFINER` functions set `search_path = ''` and schema-qualify everything.
- **Security is part of every review.** Each PR review explicitly checks RLS coverage, auth boundaries, secret handling, and PII exposure. Add **dependency/secret scanning** to CI (Rules #8–#9). When unsure whether something leaks data, treat it as if it does and lock it down.

## Backend conventions (Supabase / Postgres)

- **RLS everywhere**, from day one. Authorize by role.
- Put role/permission helpers in a **`private` schema** (never API-exposed) as **`SECURITY DEFINER`** functions with **`set search_path = ''`**; reference them in policies wrapped in a subquery: `using ( (select private.is_owner()) )`. This avoids the `profiles`-queries-`profiles` infinite-recursion trap and keeps policies fast.
- `commission_entry` RLS: staff see **only their own** rows; owner sees all.
- **`pay_ticket`** is a single Postgres function called from the POS via `supabase.rpc('pay_ticket', …)`. It runs in one implicit transaction (atomic), is `SECURITY DEFINER`, locks the ticket with `SELECT … FOR UPDATE`, and is **idempotent** (a re-call cannot double-pay or double-count commission).
- Money = `numeric(10,2)`; define and apply one rounding convention. Snapshot rates/prices on `ticket_line` so historical tickets never change if catalog rates change.
- **Migrations are versioned SQL files** managed with the Supabase CLI. Develop against a local Supabase stack before touching the cloud project. Never hand-edit the cloud DB out of band.

## Frontend conventions

- **Flutter desktop** (Windows) for the POS. Backoffice + website are Next.js (later stages).
- **UI aesthetic: never make it look light or flat.** Bold figures, elevated cards, strong hierarchy — like the KPI-card style. Dark, premium, high-contrast (no washed-out gradients that band on screens).

## Testing

Test *units differ per repo* — this repo owns the **backend/web** tests; the Flutter POS tests live in `rosea-pos`. The shared rule (Golden Rule #9) is only that tests exist, run in CI, and gate the merge.

- **Unit tests are mandatory for all logic** — write them as you build each feature; untested logic is not "done".
- **CI runs on every PR and every push to a PR (this repo):** `supabase db lint`, apply all migrations to a **fresh** DB, run the **pgTAP** suite, and (once it exists) `web` build + test. Red CI (build OR tests) **blocks the merge**. Never skip/disable tests to get green.
- **pgTAP** DB tests for `pay_ticket` (all commission/stock/idempotency cases) and for RLS (each role can/can't see the right rows).
- A demo **seed script** (salon settings, categories, services, products, staff with varied rates, a sample client) so the system is testable immediately.
- Backend e2e for the commission engine before calling Stage 1 done: call `pay_ticket` for a multi-line ticket with two different performers + a discount + a split payment, and assert the resulting `commission_entry` rows, stock changes, and totals reconcile. (The UI-level e2e of the same flow lives in `rosea-pos`.)

## Git workflow (summary)

- Branch per feature off the integration branch. **Never** commit to `main`.
- Commit messages describe the change in plain terms — **no AI attribution**.
- Open a PR → **thorough review** → only then merge. Gary does the push/PR/merge.
- No force-push to pushed branches; integrate by merge.
