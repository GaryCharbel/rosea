# Rosea — Product Roadmap

How the whole platform is delivered, stage by stage, on one Supabase backend. **Each stage is its own `spec → plan → build → reviewed-merge` cycle** (Golden Rule #1). Nothing here has hard calendar dates — it's a solo, no-charge build, so stages are sequenced by dependency and gated by owner sign-off, not a schedule. Stages ship in order; each one is usable on its own.

The Foundation schema already defines **hooks** for every later stage (columns/enums present but unused), so later stages *activate* functionality rather than reshaping the database.

---

## ▣ Stage 0+1 — Foundation + POS core  ·  *spec & plan written (this slice)*

**Goal:** the salon can ring up sales and track commissions correctly on day one.

- **Backend (`rosea`):** schema baseline, Auth (owner/staff/client) + RLS on every table, `salon_settings`, catalog (services/products/categories), staff + per-staff commission rates, tickets + per-line performer, split payments, tips, `pay_ticket`/`void_ticket` commission engine, pgTAP suite, demo seed.
- **POS (`rosea-pos`):** Flutter (Windows + Android) checkout — ring-up, per-line performer, split payment + tips, printed receipt, light-resilience (cache + idempotent retry), minimal owner commission-summary + cash-up screen.
- **Ops:** per-repo CI (pgTAP; flutter analyze/test/build), release CI → MEGA (Windows zip + APK).

**Exit criteria:** ring up a multi-line ticket with two performers + a discount, pay split → correct `commission_entry`/stock/reconciliation (backend e2e in `rosea`, UI e2e in `rosea-pos`); CI green; owner can read today's takings + per-staff commission.
**Docs:** `2026-10-30-foundation-stage1-design.md` · `2026-10-30-foundation-stage1-plan.md`.

---

## ▢ Stage 2 — Booking website  ·  *next after owners approve Stage 1*

**Goal:** clients book themselves online 24/7, and bookings land live on the POS.

- **Activates hooks:** `service.bookable_online`, `service.duration_minutes`, `ticket.appointment_id`, `client.user_id`, client-self RLS.
- **New schema:** `appointment`, `staff_schedule` (weekly working hours), `time_off`; availability derived from staff schedule + existing appointments (staff-only, no rooms).
- **New app (`rosea/web`):** Next.js booking site — client sign-up/login, browse services, pick a specific stylist, see only real open slots, book/reschedule/cancel, booking history.
- **Realtime:** a confirmed booking appears on the POS day view within seconds (Supabase Realtime).
- **Notifications:** email confirmation + reminder via a **pluggable channel layer** (email now; WhatsApp/SMS can slot in later).
- **POS:** day view of appointments; check-in → start a ticket from an appointment (walk-ins/phone bookings sit beside online ones).

**Exit criteria:** a client books online → it shows on the POS live → check-in → checkout links the ticket to the appointment; confirmation + reminder emails send.

---

## ▢ Stage 3 — Backoffice dashboard + offers

**Goal:** the owner controls everything from one place, and can run promotions.

- **New app (`rosea/web`):** owner dashboard — manage services/prices/categories, products + stock, staff + commission rates, working hours & time off, and the website (branding, bookable services).
- **Offers:** discounts (% or fixed, beyond the per-line amount), **promo codes** (online + POS). Applied automatically; commission still computed on the post-discount amount (unchanged contract).
- **Reports:** sales, staff performance, commissions — **with PDF/Excel export + a show/hide column picker** on every report table, foldable filters, per-currency amounts.

**Exit criteria:** owner creates a discount + a promo code that apply online and on the POS; every report exports and supports column show/hide; dashboard edits are live on site + POS.

---

## ▢ Stage 4 — Loyalty & extras

**Goal:** tools that bring clients back.

- **Activates hooks:** `payment_method` enum (+`gift_card`), `client.loyalty_points`, `salon_settings.loyalty_enabled`.
- **Packages:** prepaid bundles (e.g. 5-for-4) tracked and redeemed over visits.
- **Gift cards:** sold + redeemed in salon; balance tracked; usable as a payment tender on the POS (extends `pay_ticket` tender handling).
- **Memberships:** recurring perk plan (standing discount + priority booking); **renewals charged at the POS** (no external billing processor) — system flags due renewals.
- **Loyalty points:** earn per spend, redeem for money off.

**Exit criteria:** sell + redeem a gift card and a package on the POS; a member's discount auto-applies; points accrue and redeem correctly.

---

## Cross-cutting tracks (every stage, always on)

- **Security & data confidentiality** — RLS default-deny on new tables, least-privilege, no secrets in git, PII minimized/never logged; a security pass in every review.
- **Correctness → reliability → speed** — DB constraints + reconciliation, atomic/idempotent money writes, indexes for real queries, **zero N+1**, measured before claimed.
- **Automation (Rule #8)** — tests + build gate every PR; migrations/type-gen/seed/releases scripted; `rosea-pos` release → MEGA (Windows + APK); schema→Dart model regen kept in sync across repos.
- **Testing** — pgTAP for every backend change; `flutter test` for every POS feature; e2e before each stage is called done.

---

## Dependency order (why this sequence)

```
Foundation ──► Stage 1 (POS + commissions)          ← the money core; everything reads its schema
      │
      └──► Stage 2 (booking website + Realtime)      ← needs clients, schedules, appointments
                 │
                 └──► Stage 3 (dashboard + offers)    ← needs catalog/staff to manage + sales to report
                            │
                            └──► Stage 4 (loyalty)    ← needs clients, tickets, offers to build on
```

Stage 1 is the dependency root (the commission/money contract). Each later stage builds only on what's already shipped and reviewed — no stage reshapes an earlier one's contract; it activates pre-planned hooks.
