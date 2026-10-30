# Rosea — Implementation Plan (Foundation + Stage 1)

Execution rules (apply to EVERY task): review AND runtime-test every commit (not just compile); build each feature's backend + frontend as a PAIR and test it e2e before the next; all error messages actionable (P-codes + hints server-side, mapped client-side); NO Claude/AI attribution in any commit/branch/PR (the user pushes and opens PRs himself); **never commit to `main`** (branch + reviewed PR only); CI build + full test suite must pass before any merge; security & data confidentiality are first-class; **correctness → reliability → speed → features**; always check big-O and allow **zero N+1**. Branch per feature-pair; when a change spans both repos (schema in `rosea` + the consuming Dart in `rosea-pos`), land the matching branches together under one coordinated review. Full rulebook: each repo's `CLAUDE.md` (11 golden rules) — authoritative over anything below.

Canonical contract (from the spec, binding on every task): direct Postgres RPC `pay_ticket(p_ticket_id, p_payments, p_tips, p_client_tx)`; performer = `staff.id`; money = `numeric(12,2)` decimals / rates = `numeric(5,2)` percent; product commission rate on the STAFF member; incremental ticket lifecycle; money tables RPC-write-only; `salon_settings` identity singleton; oversell allowed; ledger-style void; per-line `line_discount` + generated `line_total`; cash change display-only; tips reconcilable via payment `tip_amount`; `ticket_no` identity; CLI-timestamped migrations; helpers in migration #1; staff rates column-revoked; no PIN in Stage 1; tax fixed 0.

---

## Conventions override (binding — see each repo's `CLAUDE.md`)

This plan was synthesized assuming a single monorepo + a Windows-only POS. The binding project conventions override those assumptions:

- **Hybrid two-repo layout.** `rosea` = `supabase/` + `web/` (placeholder) + `docs/`. `rosea-pos` = the Flutter app. **Wherever this plan says `pos/`, read the `rosea-pos` repo.**
- **POS targets Windows AND Android** — every `flutter build windows` is paired with `flutter build apk`.
- **Release CI (`rosea-pos`)** builds a zipped Windows build + an Android APK and uploads both to the MEGA folder (MEGAcmd; credentials in CI secrets only).
- **Cross-repo feature pairs:** a schema change in `rosea` + its consuming Dart (regenerated models/screens) in `rosea-pos` land together under one coordinated review (matching branch names).

## Phase 0 — Project & dev environment

### 0.1 Two-repo skeletons
- Goal: both repos initialized — `rosea` (platform) and `rosea-pos` (Flutter POS).
- Files: **`rosea/`** → `README.md`, `.gitignore`, `.editorconfig`, `supabase/` (via `supabase init`), `web/README.md` ("Stage 3 placeholder"), `docs/` (spec + plan already here), `docs/runbook.md`, `docs/release.md`. **`rosea-pos/`** → `flutter create .` (Windows + Android), `README.md`, `.gitignore`. Both repos already carry the same `CLAUDE.md`.
- Steps: in `rosea`: `supabase init`. In `rosea-pos`: `flutter create . --platforms=windows,android`; `.gitignore` for `env/*.json` (except value-free `env/test.json`), `**/.dart_tool/`, `**/build/`, `windows/flutter/ephemeral/`. (`supabase/.env`, `supabase/functions/.env` git-ignored in `rosea`.)
- Verify: `rosea`: `supabase start` boots the local stack. `rosea-pos`: `flutter doctor` clean; `flutter config --enable-windows-desktop`; **both** `flutter build windows` and `flutter build apk` succeed on the bare app.

### 0.2 config.toml + seed wiring (in `rosea`)
- Goal: local stack config with ordered seeds and the send-email function seam.
- Files: `supabase/config.toml`.
- Steps: set `[db] major_version=17`; `[db.seed] enabled=true sql_paths=['./seeds/00_auth.sql','./seeds/10_demo.sql']`; `[auth.email] enable_confirmations=false` (local only); `[functions.send-email] verify_jwt=false`.
- Verify: `supabase db reset` runs with no seed-path errors (seeds may be empty stubs for now).

### 0.3 POS env + fail-fast config (in `rosea-pos`)
- Goal: POS reads URL/publishable key via `--dart-define`, fails fast with an actionable message.
- Files: `pos/lib/env.dart`, `pos/env/test.json` (committed, value-free), `pos/env/local.json` + `pos/env/production.json` (git-ignored).
- Steps: `Env.assertConfigured()` throwing an actionable `StateError`; wire into `main()` before `Supabase.initialize(publishableKey: ...)`.
- Verify: `flutter run` with no defines prints the actionable config error; with `local.json` it proceeds.

### 0.4 CI — per repo (safety net, never touches cloud)
- Goal: CI in each repo; build + full test suite gate every PR (Golden Rule #9).
- Files: `rosea/.github/workflows/supabase.yml`; `rosea-pos/.github/workflows/pos-ci.yml`; `rosea-pos/.github/workflows/release.yml`.
- Steps:
  - **`rosea` supabase CI** (every PR/push): `supabase start` + `supabase db lint --level error` + `supabase test db` (pgTAP). (A `web` build+test job is added in Stage 3.)
  - **`rosea-pos` PR CI** (every PR/push): `flutter analyze` + `flutter test --dart-define-from-file=env/test.json` + verify **both** targets build (`flutter build windows` + `flutter build apk`). Red = no merge.
  - **`rosea-pos` release CI** (on a tag / release-branch merge — never `main`): `flutter build apk --release` + `flutter build windows --release` (zip), then upload **both** artifacts to the MEGA folder via MEGAcmd using `MEGA_USER`/`MEGA_PASS` repo secrets; versioned filenames (`rosea-pos-<version>.apk`, `rosea-pos-<version>-windows.zip`).
- Verify: both PR workflows green on the bare repos; a release dry-run builds both artifacts (the MEGA upload step is guarded/skipped until the secrets are set).

Acceptance (Phase 0): `rosea` — `supabase start` + `supabase db reset` succeed and supabase CI is green. `rosea-pos` — `flutter run -d windows --dart-define-from-file=env/local.json` runs and PR CI is green (both targets build). Commit on feature branches in each repo (never `main`).

---

## Phase 1 — Schema + migrations (backend-only, but each proven via `db reset`)

Each migration = one `supabase migration new <name>` file, applied via `supabase db reset`, lint-clean, with a pgTAP smoke test, before commit.

### 1.1 M01 enums + private helpers
- Goal: enums, `set_updated_at()`, and ALL `private.*` helpers in the FIRST migration.
- Files: `supabase/migrations/<ts>_foundation_enums_helpers.sql`, `supabase/tests/000-sanity.sql`.
- Steps: create `private` schema + grants; enums (`user_role`, `category_kind`, `ticket_status`, `line_type`, `payment_method`, `stock_reason`); `set_updated_at`; `private.current_role/is_owner/is_staff_or_owner/current_staff_id`.
- Verify: `supabase db reset` clean; `supabase db lint` clean; `000-sanity.sql` asserts helpers + pgTAP present.

### 1.2 M02 salon_settings singleton
- Files: `<ts>_salon_settings.sql`.
- Steps: identity `check(id=1)` table with name/currency/timezone/address/tax_rate/loyalty_enabled/receipt_header/receipt_footer; updated trigger; seed one row.
- Verify: `db reset`; `insert into salon_settings(name) values('x')` fails (singleton); row id=1 exists.

### 1.3 M03 staff + staff_public view
- Files: `<ts>_staff.sql`.
- Steps: `staff` with `commission_rate`, `product_commission_rate` (nullable); `staff_public` view (id/name/title/active, NO rates).
- Verify: `db reset`; `select * from staff_public` has no rate columns.

### 1.4 M04 client; 1.5 M05 profiles + auth bridge
- Files: `<ts>_client.sql`, `<ts>_profiles_auth.sql`.
- Steps (M05): `profiles`; `handle_new_user` trigger; `guard_profile_role_change` trigger; `set_user_role` RPC; `custom_access_token_hook` + auth-admin grants.
- Verify: `db reset`; sign up a user (CLI/admin API) → `profiles` row `role='client'` appears; decode a fresh JWT → `user_role` claim present after registering the hook in Dashboard (document in runbook).

### 1.6 M06–M08 catalog
- Files: `<ts>_category.sql`, `<ts>_service.sql`, `<ts>_product.sql`.
- Steps: tables + updated triggers + kind-guard triggers (actionable raises) + partial active indexes.
- Verify: `db reset`; inserting a service with a product-kind category raises the actionable message; product `stock_quantity` has no `>=0` CHECK (oversell allowed).

### 1.7 M09–M11 ticket, ticket_line, immutability guards
- Files: `<ts>_ticket.sql`, `<ts>_ticket_line.sql`.
- Steps: `ticket` (identity `ticket_no`, `created_by default auth.uid()`, `paid_tx`/`void_tx` unique, appointment pinned null, closed_at CHECK); `ticket_line` (generated `line_total`, `line_discount` CHECK, kind CHECK, whole-unit product CHECK, performer_staff_id→staff); `guard_child_only_when_open` triggers on line/payment/tip.
- Verify: `db reset`; a generated `line_total` equals `round(unit_price*qty,2)-line_discount`; editing a line on a non-open ticket raises the actionable "already closed".

### 1.8 M12–M15 payment, tip, commission_entry, stock_movement
- Files: `<ts>_payment_tip.sql`, `<ts>_commission_entry.sql`, `<ts>_stock_movement.sql`.
- Steps: `payment`/`tip` (`amount <> 0`, `client_tx`), `commission_entry` (base/rate/amount, is_reversal, unique earning + unique reversal per line), `stock_movement`; all indexes.
- Verify: `db reset` + `db lint` clean; unique indexes present via `list_tables`/`\d`.

Acceptance (Phase 1): `supabase db reset` applies all migrations cleanly; `supabase db lint --level error` clean; `get_advisors(security)` shows RLS not-yet-enabled warnings only (fixed in Phase 2). Commit.

---

## Phase 2 — Auth + RLS (BE) paired with POS login/shell (FE)

### 2.1 RLS on every table + helpers-based policies
- Goal: enable RLS everywhere; policies per the §6.2 matrix; staff rate columns revoked.
- Files: `<ts>_rls.sql`.
- Steps: `enable row level security` on all public tables; `revoke select(commission_rate,product_commission_rate) on staff from authenticated`; grant `staff_public`; policies for profiles/salon_settings/catalog/staff/client/ticket/ticket_line/payment/tip/commission_entry/stock_movement; `private.my_ticket_ids()` (performer = `current_staff_id()`); money tables `using(false) with check(false)` + REVOKE.
- Verify: `db reset`; `get_advisors(security)` clean (RLS on every table). pgTAP `010-rls-foundation.sql`: client isolation; anon sees catalog only, no tickets; staff cannot UPDATE own `commission_rate` (value provably unchanged via column revoke); staff cannot read rate columns (`select commission_rate from staff` denied); staff cannot edit `salon_settings` (`42501`); owner full control; staff reads only own `commission_entry`.

### 2.2 POS: Supabase init + session + login (FE, paired with 2.1)
- Goal: real login against local stack; role decoded from JWT with profiles fallback.
- Files: `pos/lib/core/supabase/supabase_init.dart`, `pos/lib/features/auth/session_controller.dart`, `pos/lib/features/auth/ui/login_screen.dart`, `pos/lib/core/errors/app_error.dart`, `pos/lib/router.dart`.
- Steps: PKCE init (publishable key); `SessionController` AsyncNotifier with sealed `AuthState` + `AuthApiException` mapping; sync boot redirect off `currentSession`; `AppError` sealed type.
- Verify (e2e): `supabase db reset`; seed an owner (Phase 5 seed or manual); `flutter run -d windows`; log in as owner → lands on shell; wrong password → actionable "Email or password is incorrect"; a cashier session querying `staff.commission_rate` is denied (confirm the no-rate-leak rule live).

### 2.3 POS: performer selector (FE) — no PIN
- Goal: choose active performer from `staff_public`; per-line override.
- Files: `pos/lib/features/auth/active_staff.dart`, `pos/lib/features/auth/ui/staff_switch_screen.dart`.
- Steps: `ActiveStaff` notifier selecting from cached `staff_public` (id/name/active); NO `verify_pin` call (Stage 1.5 deferred).
- Verify: select a performer; it defaults onto new lines; inactive staff not selectable.

Acceptance (Phase 2): login + role gating work on the device; RLS pgTAP green including the rate-leak and own-commission assertions; `get_advisors` clean. Commit.

---

## Phase 3 — Commission engine (`pay_ticket`/`void_ticket`) + pgTAP

### 3.1 pay_ticket RPC
- Goal: the one atomic, idempotent money path per §7.2.
- Files: `<ts>_pay_ticket.sql` (incl. `_pay_ticket_result` helper, revoked from clients).
- Steps: implement §7.2 steps 1–14; raise P0001/P0002/P0004 + `insufficient_privilege` with actionable messages; advisory lock; `paid_tx` idempotent replay; recompute totals; split-payment exact match on APPLIED amounts; payment-embedded `tip_amount`/`tip_staff_id` → `tip` rows; standalone `p_tips`; per-line rate resolution (service→`commission_rate`, product→`product_commission_rate` only if eligible+non-null else 0); unconditional stock decrement (oversell allowed); `_pay_ticket_result` returns the §7.4 receipt payload with performer names and no commission. Grant execute to `authenticated` (in-function role gate is the real guard); revoke `_pay_ticket_result`.
- Verify: see 3.3.

### 3.2 void_ticket RPC
- Files: `<ts>_void_ticket.sql`.
- Steps: owner-only; `void_tx` idempotent; negative commission/payment/tip rows; `void_restore` stock; `paid→void`.
- Verify: see 3.3.

### 3.3 pgTAP commission + stock + idempotency + void suite
- Goal: executable proof of every resolved rule.
- Files: `supabase/tests/020-pay-commission.sql`, `030-pay-stock.sql`, `040-pay-idempotency.sql`, `050-pay-split-tips.sql`, `supabase/tests/fixtures.sql`, `supabase/migrations/99999999_test_helpers.sql` (local-only pgTAP/basejump install, excluded from `db push`).
- Steps: build the §7.6 fixtures and assert cases 1–17, in particular: product rate from STAFF (case 2 → 5.00; case 16 null→0); non-eligible → 0 (case 3); open ticket → zero commission; rounding half-up (case 17 → 5.59); oversell SUCCEEDS driving stock negative (case 10); idempotent replay (case 11 → exactly 1 entry); P0002 on mismatch incl. overpay (applied≠total, cases 7–8); P0004 empty; client role rejected (case 13); void nets to 0 + restocks + replay (cases 14–15).
- Verify: `supabase db reset && supabase test db` green OFFLINE; every error assertion checks the P-code token.

Acceptance (Phase 3): `supabase test db` fully green; `_pay_ticket_result` returns performer names + no commission/rates. Commit.

---

## Phase 4 — POS core, built BE+FE paired per feature, e2e before next

Each sub-phase pairs the (already-built) backend with its FE slice and is e2e-tested against the local stack before moving on.

### 4.1 Catalog cache + grid
- Goal: Drift read-through cache of catalog + `staff_public`; reactive grid; soft-delete aware sync.
- Files: `pos/lib/core/db/local_db.dart` (+ `.g.dart`), `pos/lib/core/db/connection.dart`, `pos/lib/features/catalog/catalog_repo.dart`, `catalog_sync_controller.dart`, `providers.dart`, `ui/catalog_panel.dart`.
- Steps: Drift tables `CachedCategories/Services/Products/Staff` (NO rate columns) + `SyncWatermark`; watermark sync over `updated_at` (active=false bumps updated_at → deactivations propagate); `connectivity_plus` resync on reconnect.
- Verify (e2e): `db reset`; run POS; kill WiFi → catalog still renders from cache; deactivate a service server-side → it disappears after sync; confirm no rate columns exist in the local DB.

### 4.2 Ticket + lines with per-line performer (incremental lifecycle)
- Goal: open a server ticket, add lines with performer chips.
- Files: `pos/lib/features/checkout/model/{draft_ticket,draft_line}.dart`, `checkout_draft.dart`, `totals.dart`, `pos/lib/data/ticket_repo.dart`, `ui/{checkout_screen,ticket_panel,performer_picker}.dart`.
- Steps: opening a ticket inserts an open `ticket` server-side (gets `ticket_no`); adding a line inserts a `ticket_line` with `performer_staff_id`; totals derived (incl. `line_discount` from a %→amount client conversion); performer chip per line.
- Verify (e2e): ring a multi-line ticket with two different performers; confirm `ticket_line.performer_staff_id` rows; staff A cannot read staff B's unrelated ticket (RLS); editing a line on a (manually) paid ticket is rejected.

### 4.3 Split payments + tips (applied amounts; cash change display-only)
- Goal: payment sheet with live remaining/change; tip sheet per staff.
- Files: `pos/lib/features/checkout/ui/{payment_sheet,tip_sheet}.dart`, `pay_validator.dart`, `pos/lib/core/money.dart`.
- Steps: `money.dart` cents↔decimal codec (unit-tested); PayValidator forbids underpay, forbids non-cash overpay, allows cash overpay as change (display only); payload sends APPLIED amounts (capped), tips as payment `tip_amount`/`tip_staff_id` and/or `p_tips`.
- Verify (unit + e2e): `money.dart` round-trip test (no 100× error); exact split; cash overpayment shows change but sends applied=total; card overpayment blocked client-side with actionable copy.

### 4.4 Pay flow + outbox + receipt (pairs with Phase 3 RPC)
- Goal: durable idempotent pay → print receipt.
- Files: `pos/lib/features/checkout/pay_controller.dart`, `pos/lib/features/outbox/{outbox_controller.dart,ui/pending_sync_screen.dart}`, `pos/lib/features/receipt/{receipt_printer.dart,pdf_receipt_printer.dart}`.
- Steps: mint `p_client_tx` once; durable outbox row referencing the server ticket id; single-flight flush calling `supabase.rpc('pay_ticket', ...)`; boot recovery `sending→pending`; transient/transport → retry same key; RLS/validation → mark failed, surface server message verbatim; render receipt from `_pay_ticket_result` (performer names, discounts, split tenders, tips, change, totals, salon header/footer); clear draft.
- Verify (e2e): online pay (split cash+card + tip) → status paid, correct per-staff commission (server), receipt prints; blip-during-pay → queued → auto-confirm → receipt; kill app mid-send → boot recovery resends → exactly one ticket (idempotent); double-tap → one ticket; direct `supabase.rpc('pay_ticket')` from a client-role JWT denied.

### 4.5 Owner commission + cash-up read-out
- Goal: minimal owner screen to reconcile payroll + till (closes the reporting gap).
- Files: `pos/lib/features/staff_admin/ui/{commission_summary_screen,cash_up_screen}.dart`, `pos/lib/data/ticket_repo.dart` (commission read-back).
- Steps: owner-gated route; commission grouped by staff + date (reads RLS-protected `commission_entry`); cash-up = `sum(payment.amount)` + `sum(tip.amount)` per method over a date. No PDF/Excel/column-picker (dashboard stage).
- Verify (e2e): after a paid ticket, owner sees correct per-staff commission and a cash-up total reconciling to tenders (`payment.amount + tip.amount`); a staff session cannot open this screen / sees only own commission.

### 4.6 Error-handling + actionable-copy tests
- Files: `pos/test/map_pay_error_test.dart`, `pos/test/checkout_cart_widget_test.dart`, `pos/lib/core/errors/app_error.dart`.
- Steps: map P0001/P0002/P0004 + `insufficient_privilege`/`42501` to specific copy; widget test asserts a P0002 shows "Adjust the split so it matches" and never "unexpected error".
- Verify: `flutter test` green; no mapped path returns a generic message.

Acceptance (Phase 4): each sub-feature e2e-tested against the local stack before the next; all unit/widget tests green; bold/elevated UI (figures hero, elevated cards, solid performer chips). Commit each pair on its branch.

---

## Phase 5 — Seed + full e2e verification + sign-off

### 5.1 Seeds (auth + demo)
- Goal: `db reset` leaves a ringable AND loginable demo salon.
- Files: `supabase/seeds/00_auth.sql`, `supabase/seeds/10_demo.sql`.
- Steps: `00_auth.sql` creates login-capable owner/staff `auth.users` + identities (pgcrypto, known password) + `profiles` (owner, staff with `staff_id` link) — LOCAL ONLY, excluded from `db push`; `10_demo.sql` seeds salon_settings, ~3 staff (distinct rates, one with null `product_commission_rate`), categories, ~8 services (`bookable_online` set, unused), ~5 products (incl. one commission-eligible with null staff product rate → earns 0, some not eligible), a sample client. Idempotent `on conflict do nothing`.
- Verify: `supabase db reset` → log in as `owner@rosea.test` and see catalog; staff #2 linked to a loginable account.

### 5.2 Flutter integration test (the pair-test gate)
- Files: `pos/integration_test/checkout_payment_flow_test.dart`, `pos/integration_test/_helpers.dart`.
- Steps: sign in as owner; ring 2 performers + a line discount; pay split with a tip; capture the paid ticket id from the result; assert `commission_entry` per staff (post-discount × STAFF rate, non-eligible=0), tip separate, `payment.amount` sums to total (applied), and the retry path treats `P0001` already-paid as success.
- Verify: with the local stack up and freshly reset, `flutter test integration_test --dart-define=...` green.

### 5.3 Manual runtime sign-off (the owner demo)
- Steps: `db reset`; launch POS; log in as owner; ring Full Color (Lea), Women's Cut with 20% discount (Maya, shows $9 off → $36), Hair Oil (Lea), Gift Bag (Maya, not eligible); total $196; pay split $100 cash + $96 card + $10 tip to Lea; print receipt; open owner commission screen and verify Maya = 36×40% = $14.40, Lea = 120×50% + 35×(Lea product rate), tip $10 under tips not commission; re-trigger send (pull cable mid-confirm) → "already paid", no duplicate rows.
- Verify: all figures match; receipt shows lines+performers, discount, split tenders, tip, change, totals, salon header/footer, NO commission.

### 5.4 Pre-commit gate (mechanize the standing rules)
- Steps/Files: `docs/runbook.md` documents and (optional) a local hook runs in order: `supabase db reset` → `supabase db lint --level error` → `supabase test db` → `cd pos && dart analyze && flutter test && flutter test integration_test`.
- Verify: whole gate green before any human review/commit.

### 5.5 Production deploy runbook (first-owner bootstrap)
- Files: `docs/runbook.md`, `docs/release.md`.
- Steps: document `supabase link` → `migration list` → `db push --dry-run` → `db push` (NEVER `--include-seed`); register the Custom Access Token hook in Dashboard; set Edge Function secrets; the one-time first-owner bootstrap: owner signs up, then run `update public.profiles set role='owner' where id='<uid>'` as service_role in the SQL editor; Windows POS release build via `flutter build windows --release --dart-define-from-file=env/production.json`, zip the Release folder (or MSIX with a persistent self-signed cert imported to Trusted People).
- Verify: a clean linked project reaches a working owner login after the documented steps.

Acceptance (Stage 1 DONE — all must hold):
- `supabase db reset` applies every migration + both seeds cleanly → ringable + loginable salon; `get_advisors(security)` clean (RLS on every table).
- `supabase test db` green OFFLINE (RLS + pay/void: commission incl. null-staff-product-rate=0, rounding half-up, open-ticket=0, oversell-succeeds, idempotency+void, split/tips/mismatch/empty).
- Roles resolve from `profiles`; staff cannot read or edit rates (column-revoked) or `salon_settings`; staff reads only own commission; cashier till never sees rates/commission math.
- Multi-line tickets with per-line `performer_staff_id`; `pay_ticket` atomic + idempotent (`p_client_tx`/`paid_tx`/advisory lock); balance = `sum(payment.amount)=total` (applied; cash change display-only); split + per-staff tips (reconcilable via payment `tip_amount`); oversell allowed; commission only on paid tickets, per line, post-discount, STAFF rates; ledger-style void.
- Receipt renders fully from `_pay_ticket_result` (performer names, discounts, tenders, tips, change, totals, header/footer) with NO commission; owner commission + cash-up screen reconciles payroll and till.
- Flutter unit + widget + integration green; no "unexpected error" anywhere (every pay failure maps to actionable copy).
- Every commit runtime-tested (not just compiled); no Claude/AI attribution in git history.
- Deferred hooks present but unused: `appointment_id`, `bookable_online`/`duration_minutes`, `client.loyalty_points`, `salon_settings.tax_rate`/`loyalty_enabled`, `payment_method` extensibility, channel-layer stub, UUID keys for multi-location, staff-PIN (1.5).
