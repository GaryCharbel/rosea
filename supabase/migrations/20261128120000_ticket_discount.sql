-- M18 — ticket-level discount (a whole-ticket discount on top of any per-line ones).
--
-- Stored on the ticket; applied atomically inside pay_ticket. The discount is distributed
-- across the lines PRO-RATA by each line's line_total, using largest-remainder rounding so
-- the per-line allocations sum to EXACTLY the ticket discount (no cent drift). Commission
-- stays "rate x (line net after BOTH discounts)", so the per-line commission engine and
-- the "commission = rate x post-discount amount" invariant are untouched; commission_entry
-- .base_amount becomes the post-ticket-discount net, which void_ticket already reverses by
-- negating the stored rows (so voids stay consistent with no change there).
--
-- discount_total = sum(line_discount) + ticket_discount. With p_ticket_discount = 0 the
-- allocation is zero on every line, so all prior pay/commission behaviour is unchanged.

alter table public.ticket
  add column ticket_discount numeric(12,2) not null default 0 check (ticket_discount >= 0);

comment on column public.ticket.ticket_discount is
  'Whole-ticket discount (on top of per-line discounts). Applied + frozen by pay_ticket, '
  'distributed across lines pro-rata for commission. Part of discount_total.';

-- pay_ticket gains p_ticket_discount. Drop the old 4-arg signature first so there is a
-- single pay_ticket (the new default makes old 4-param callers resolve to it).
drop function if exists public.pay_ticket(uuid, jsonb, jsonb, uuid);

create or replace function public.pay_ticket(
  p_ticket_id       uuid,
  p_payments        jsonb   default '[]'::jsonb,
  p_tips            jsonb   default '[]'::jsonb,
  p_client_tx       uuid    default null,
  p_ticket_discount numeric default 0
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ticket        public.ticket;
  v_subtotal      numeric(12,2);
  v_line_discount numeric(12,2);
  v_gross_total   numeric(12,2);   -- sum of line_total, before the ticket discount
  v_discount      numeric(12,2);   -- line discounts + the ticket discount
  v_total         numeric(12,2);   -- gross_total - ticket discount
  v_pay_sum       numeric(12,2);
  v_taken_by      uuid;
  v_pay           jsonb;
  v_tip           jsonb;
  v_line          record;
  v_rate          numeric(5,2);
  v_base          numeric(12,2);   -- line_total minus this line's share of the ticket discount
  v_amount        numeric(12,2);
begin
  -- 1. Authz.
  if not private.is_staff_or_owner() then
    raise exception 'Only salon staff can take payments.'
      using errcode = 'insufficient_privilege';
  end if;

  -- 2. Shape validation.
  if p_client_tx is null then
    raise exception 'Missing the checkout transaction id. Retry the payment from the POS.'
      using errcode = 'P0002';
  end if;
  if jsonb_typeof(p_payments) is distinct from 'array'
     or jsonb_typeof(p_tips) is distinct from 'array' then
    raise exception 'Payments and tips must each be a list. Retry the payment from the POS.'
      using errcode = 'P0002';
  end if;
  if p_ticket_discount is null or p_ticket_discount < 0 then
    raise exception 'The ticket discount must be zero or more. Fix it and retry.'
      using errcode = 'P0002';
  end if;

  -- 3. Advisory lock: serialize concurrent pays of the SAME ticket.
  perform pg_advisory_xact_lock(hashtextextended(p_ticket_id::text, 0));

  -- 4. Load + lock the ticket.
  select * into v_ticket from public.ticket where id = p_ticket_id for update;
  if not found then
    raise exception 'That ticket no longer exists. Refresh the POS and start a new ticket.'
      using errcode = 'P0001';
  end if;

  -- 5. Idempotent replay / terminal states.
  if v_ticket.status = 'paid' then
    if v_ticket.paid_tx = p_client_tx then
      return public._pay_ticket_result(p_ticket_id);   -- exact replay: no-op
    end if;
    raise exception 'This ticket is already paid. Open a new ticket to ring up more.'
      using errcode = 'P0001';
  elsif v_ticket.status = 'void' then
    raise exception 'This ticket was voided and cannot be paid. Start a new ticket.'
      using errcode = 'P0001';
  end if;

  -- 6. Recompute totals from the lines (source of truth — never the client).
  select coalesce(sum(round(l.unit_price * l.qty, 2)), 0),
         coalesce(sum(l.line_discount), 0),
         coalesce(sum(l.line_total), 0)
    into v_subtotal, v_line_discount, v_gross_total
  from public.ticket_line l
  where l.ticket_id = p_ticket_id;

  -- 6b. The ticket discount can't exceed what's left after per-line discounts.
  if p_ticket_discount > v_gross_total then
    raise exception 'The ticket discount (%) is more than the ticket (%). Reduce it and retry.',
      p_ticket_discount, v_gross_total using errcode = 'P0002';
  end if;

  v_discount := v_line_discount + p_ticket_discount;
  v_total    := v_gross_total - p_ticket_discount;

  select coalesce(sum((e->>'amount')::numeric), 0)
    into v_pay_sum
  from jsonb_array_elements(p_payments) e;

  -- 7. Empty-ticket guard.
  if not exists (select 1 from public.ticket_line where ticket_id = p_ticket_id) then
    raise exception 'Add at least one service or product before taking payment.'
      using errcode = 'P0004';
  end if;
  if v_total <= 0 and v_pay_sum <> 0 then
    raise exception 'This ticket totals 0 — remove the payment. A fully-discounted ticket is paid with no tender.'
      using errcode = 'P0004';
  end if;

  -- 7b. Every applied payment and standalone tip must be a POSITIVE amount.
  if exists (select 1 from jsonb_array_elements(p_payments) e
               where coalesce((e->>'amount')::numeric, 0) <= 0) then
    raise exception 'Every payment must be a positive amount. Fix the split and retry.'
      using errcode = 'P0002';
  end if;
  if exists (select 1 from jsonb_array_elements(p_tips) e
               where coalesce((e->>'amount')::numeric, 0) <= 0) then
    raise exception 'Every tip must be a positive amount.'
      using errcode = 'P0002';
  end if;

  -- 8. Split-payment validation: applied amounts must sum EXACTLY to the total.
  if v_pay_sum <> v_total then
    raise exception 'Payments total % but the ticket is %. Adjust the split so it matches.',
      v_pay_sum, v_total using errcode = 'P0002';
  end if;

  v_taken_by := coalesce(private.current_staff_id(), v_ticket.opened_by);

  -- 9. Payments (+ inline tips carried on a payment element).
  for v_pay in select value from jsonb_array_elements(p_payments) loop
    insert into public.payment(ticket_id, method, amount, reference, taken_by, client_tx)
    values (
      p_ticket_id,
      (v_pay->>'method')::public.payment_method,
      (v_pay->>'amount')::numeric,
      v_pay->>'reference',
      v_taken_by,
      p_client_tx);

    if coalesce((v_pay->>'tip_amount')::numeric, 0) > 0 then
      insert into public.tip(ticket_id, staff_id, amount, method, client_tx)
      values (
        p_ticket_id,
        (v_pay->>'tip_staff_id')::uuid,
        (v_pay->>'tip_amount')::numeric,
        (v_pay->>'method')::public.payment_method,
        p_client_tx);
    end if;
  end loop;

  -- 10. Standalone tips.
  for v_tip in select value from jsonb_array_elements(p_tips) loop
    insert into public.tip(ticket_id, staff_id, amount, method, client_tx)
    values (
      p_ticket_id,
      (v_tip->>'staff_id')::uuid,
      (v_tip->>'amount')::numeric,
      (v_tip->>'method')::public.payment_method,
      p_client_tx);
  end loop;

  -- 11. Commission: distribute the ticket discount across lines pro-rata by line_total
  --     (largest-remainder in integer cents, so the allocations sum to exactly the ticket
  --     discount), then freeze rate + commission on the POST-discount base per line.
  for v_line in
    with l0 as (
      select l.id, l.line_type, l.line_total, l.performer_staff_id, l.product_id,
             round(l.line_total * 100)::bigint as lt_c,
             s.commission_rate, s.product_commission_rate, pr.commission_eligible
      from public.ticket_line l
      join public.staff s on s.id = l.performer_staff_id
      left join public.product pr on pr.id = l.product_id
      where l.ticket_id = p_ticket_id
    ),
    tot as (select coalesce(sum(lt_c), 0)::bigint as t from l0),
    f as (
      select l0.*,
        case when (select t from tot) = 0 then 0::bigint
             else (round(p_ticket_discount * 100)::bigint * lt_c) / (select t from tot) end as fl,
        case when (select t from tot) = 0 then 0::bigint
             else (round(p_ticket_discount * 100)::bigint * lt_c) % (select t from tot) end as frac
      from l0
    ),
    k as (select (round(p_ticket_discount * 100)::bigint - coalesce(sum(fl), 0)) as leftover from f),
    ranked as (
      select f.*, row_number() over (order by frac desc, id) as rn from f
    )
    select id, line_type, line_total, performer_staff_id, product_id,
           commission_rate, product_commission_rate, commission_eligible,
           lt_c,
           (fl + case when rn <= (select leftover from k) then 1 else 0 end) as alloc_c
    from ranked
  loop
    if v_line.line_type = 'service' then
      v_rate := v_line.commission_rate;
    elsif v_line.commission_eligible and v_line.product_commission_rate is not null then
      v_rate := v_line.product_commission_rate;
    else
      v_rate := 0;
    end if;

    -- post-ticket-discount base for this line (exact to the cent)
    v_base   := round((v_line.lt_c - v_line.alloc_c)::numeric / 100, 2);
    v_amount := round(v_base * v_rate / 100, 2);

    update public.ticket_line
       set commission_rate_snapshot = v_rate,
           commission_amount        = v_amount
     where id = v_line.id;

    insert into public.commission_entry(
      staff_id, ticket_id, ticket_line_id, line_type,
      base_amount, rate, amount, is_reversal)
    values (
      v_line.performer_staff_id, p_ticket_id, v_line.id, v_line.line_type,
      v_base, v_rate, v_amount, false);
  end loop;

  -- 12. Stock: decrement tracked product lines unconditionally (oversell allowed).
  for v_line in
    select l.product_id, l.qty
    from public.ticket_line l
    join public.product p on p.id = l.product_id
    where l.ticket_id = p_ticket_id and l.line_type = 'product' and p.track_stock
  loop
    update public.product
       set stock_quantity = stock_quantity - v_line.qty::integer
     where id = v_line.product_id;

    insert into public.stock_movement(product_id, reason, qty_delta, ticket_id, created_by)
    values (v_line.product_id, 'sale', -(v_line.qty::integer), p_ticket_id,
            private.current_staff_id());
  end loop;

  -- 13. Flip to paid (last — the ticket_line guard allows writes only while 'open').
  update public.ticket
     set status          = 'paid',
         subtotal        = v_subtotal,
         ticket_discount = p_ticket_discount,
         discount_total  = v_discount,
         total           = v_total,
         paid_tx         = p_client_tx,
         closed_at       = now()
   where id = p_ticket_id;

  -- 14. Receipt payload.
  return public._pay_ticket_result(p_ticket_id);
end;
$$;

revoke all on function public.pay_ticket(uuid, jsonb, jsonb, uuid, numeric) from public;
grant execute on function public.pay_ticket(uuid, jsonb, jsonb, uuid, numeric) to authenticated;
