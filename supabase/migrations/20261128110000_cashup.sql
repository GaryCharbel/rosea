-- M17 — cashup: owner-only till read-out, aggregated server-side.
--
-- Lifts the former client-side aggregation into one place and gates it on the owner.
-- This is the ONLY path that exposes staff.commission_rate to the app, and only to the
-- owner: the till (authenticated non-owner) still cannot read the rate columns directly.
-- Amounts are returned as integer CENTS (round(numeric*100)) so the client never does
-- float math. Voids net automatically — payment/tip/commission amounts are stored
-- negative on a void reversal, so the SUMs already subtract them.
--
-- Split in two: private._cashup does the aggregation (no gate) so pgTAP can exercise the
-- numbers directly; public.cashup is the owner-gated entry point. search_path='' +
-- schema-qualified, SECURITY DEFINER (reads across RLS), per the pay_ticket convention.

create or replace function private._cashup(p_from timestamptz, p_to timestamptz)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'range', jsonb_build_object('from', p_from, 'to', p_to),
    'takings_by_method', coalesce((
      select jsonb_object_agg(method, cents)
      from (
        select p.method::text as method, round(sum(p.amount) * 100)::bigint as cents
        from public.payment p
        where p.created_at >= p_from and p.created_at < p_to
        group by p.method
      ) m
    ), '{}'::jsonb),
    'gross_takings', coalesce((
      select round(sum(p.amount) * 100)::bigint from public.payment p
      where p.created_at >= p_from and p.created_at < p_to), 0),
    'tip_total', coalesce((
      select round(sum(t.amount) * 100)::bigint from public.tip t
      where t.created_at >= p_from and t.created_at < p_to), 0),
    'ticket_count', coalesce((
      select count(*)::bigint from public.ticket tk
      where tk.status = 'paid' and tk.closed_at >= p_from and tk.closed_at < p_to), 0),
    'avg_ticket', coalesce((
      select round(avg(tk.total) * 100)::bigint from public.ticket tk
      where tk.status = 'paid' and tk.closed_at >= p_from and tk.closed_at < p_to), 0),
    'by_staff', coalesce((
      select jsonb_agg(
               jsonb_build_object(
                 'name', st.name,
                 'rate', st.commission_rate,                 -- configured services rate (%)
                 'services_count', agg.services_count,
                 'services_cents', agg.services_cents,
                 'products_cents', agg.products_cents,
                 'commission_cents', agg.commission_cents
               ) order by st.name
             )
      from (
        select
          c.staff_id,
          -- net service lines (earnings minus reversals in the window)
          count(*) filter (where c.line_type = 'service' and not c.is_reversal)
            - count(*) filter (where c.line_type = 'service' and c.is_reversal) as services_count,
          -- base_amount / amount are signed (negative on reversal), so the SUMs net voids
          coalesce(round(sum(c.base_amount) filter (where c.line_type = 'service') * 100), 0)::bigint as services_cents,
          coalesce(round(sum(c.base_amount) filter (where c.line_type = 'product') * 100), 0)::bigint as products_cents,
          coalesce(round(sum(c.amount) * 100), 0)::bigint as commission_cents
        from public.commission_entry c
        where c.earned_at >= p_from and c.earned_at < p_to
        group by c.staff_id
      ) agg
      join public.staff st on st.id = agg.staff_id
    ), '[]'::jsonb)
  );
$$;

comment on function private._cashup(timestamptz, timestamptz) is
  'Internal cash-up aggregation (no auth gate). Call public.cashup, which gates on owner.';

create or replace function public.cashup(p_from timestamptz, p_to timestamptz)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.is_owner() then
    raise exception 'Only the salon owner can read the cash-up.' using errcode = '42501';
  end if;
  return private._cashup(p_from, p_to);
end;
$$;

comment on function public.cashup(timestamptz, timestamptz) is
  'Owner-only till read-out: takings by method, tips, ticket count/avg, and per-staff '
  'rate + services + commission. Amounts are integer cents. Non-owners get 42501.';

-- Owner-gated entry point: signed-in users may call it, the body refuses non-owners.
-- The internal aggregator lives in the unexposed private schema; locked from clients.
revoke all on function public.cashup(timestamptz, timestamptz) from public;
grant execute on function public.cashup(timestamptz, timestamptz) to authenticated;
revoke all on function private._cashup(timestamptz, timestamptz) from public;
