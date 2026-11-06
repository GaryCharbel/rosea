-- Phase 3 hardening — review fixes for the money functions (both LOW findings).
--
-- (1) _pay_ticket_result now reports the NET payments/tips per method/staff (dropping
--     net-zero entries) instead of every positive row. A paid ticket is unchanged (one
--     row per method); a VOIDED ticket now shows empty payments/tips + tip_total 0,
--     reflecting that nothing is collected — instead of echoing the original positives.
-- (2) pay_ticket pre-checks that the checkout id was not already used to pay a DIFFERENT
--     ticket (paid_tx is UNIQUE) and raises an actionable P0001, instead of letting a
--     raw unique-violation escape at the final write. (void_ticket gets the symmetric
--     void_tx guard in its own migration.)
--
-- Both are create-or-replace: the originals shipped in 20261106101500_pay_ticket.sql
-- (already merged), so the fixes land as a forward migration.

-- ---------------------------------------------------------------------------
create or replace function public._pay_ticket_result(p_ticket_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'ticket_id',      t.id,
    'ticket_no',      t.ticket_no,
    'status',         t.status,
    'subtotal',       t.subtotal,
    'discount_total', t.discount_total,
    'total',          t.total,
    'closed_at',      t.closed_at,
    'salon', (
      select jsonb_build_object(
        'name',           s.name,
        'address',        s.address,
        'receipt_header', s.receipt_header,
        'receipt_footer', s.receipt_footer,
        'currency',       s.currency)
      from public.salon_settings s where s.id = 1),
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
        'name',           l.name_snapshot,
        'line_type',      l.line_type,
        'performer_name', st.name,
        'unit_price',     l.unit_price,
        'qty',            l.qty,
        'line_discount',  l.line_discount,
        'line_total',     l.line_total) order by l.created_at)
      from public.ticket_line l
      join public.staff st on st.id = l.performer_staff_id
      where l.ticket_id = t.id), '[]'::jsonb),
    -- NET per method (a void's +/- rows cancel to 0 and drop out)
    'payments', coalesce((
      select jsonb_agg(jsonb_build_object('method', g.method, 'amount', g.amt) order by g.method)
      from (
        select method, sum(amount) as amt
        from public.payment where ticket_id = t.id
        group by method having sum(amount) <> 0
      ) g), '[]'::jsonb),
    -- NET per staff+method
    'tips', coalesce((
      select jsonb_agg(jsonb_build_object('staff_name', st.name, 'amount', g.amt, 'method', g.method)
               order by st.name)
      from (
        select staff_id, method, sum(amount) as amt
        from public.tip where ticket_id = t.id
        group by staff_id, method having sum(amount) <> 0
      ) g
      join public.staff st on st.id = g.staff_id), '[]'::jsonb),
    'tip_total', coalesce((
      select sum(amount) from public.tip where ticket_id = t.id), 0)  -- net: 0 after a void
  )
  from public.ticket t
  where t.id = p_ticket_id;
$$;

revoke all on function public._pay_ticket_result(uuid) from public;

-- ---------------------------------------------------------------------------
create or replace function public.pay_ticket(
  p_ticket_id uuid,
  p_payments  jsonb default '[]'::jsonb,
  p_tips      jsonb default '[]'::jsonb,
  p_client_tx uuid  default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ticket   public.ticket;
  v_subtotal numeric(12,2);
  v_discount numeric(12,2);
  v_total    numeric(12,2);
  v_pay_sum  numeric(12,2);
  v_taken_by uuid;
  v_pay      jsonb;
  v_tip      jsonb;
  v_line     record;
  v_rate     numeric(5,2);
  v_amount   numeric(12,2);
begin
  -- 1. Authz (RLS-class: no token needed, the role decides).
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

  -- 5b. The checkout id must belong to THIS sale. If it already paid a different ticket
  --     (paid_tx is UNIQUE), the client reused it in error — surface an actionable
  --     message instead of a raw unique-violation at the final write.
  if exists (select 1 from public.ticket
               where paid_tx = p_client_tx and id <> p_ticket_id) then
    raise exception 'This checkout id was already used on another sale. Start a fresh ticket and retry.'
      using errcode = 'P0001';
  end if;

  -- 6. Recompute totals from the lines (source of truth — never the client).
  select coalesce(sum(round(l.unit_price * l.qty, 2)), 0),
         coalesce(sum(l.line_discount), 0),
         coalesce(sum(l.line_total), 0)
    into v_subtotal, v_discount, v_total
  from public.ticket_line l
  where l.ticket_id = p_ticket_id;

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

  -- 7b. Every applied payment and standalone tip must be a POSITIVE amount (never trust
  --     the client: a negative element could satisfy the split-sum check yet write a
  --     bogus negative money row on a sale). Also converts a missing/null amount into
  --     actionable copy instead of a raw NOT NULL violation.
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

  -- Attribute the money rows to the caller's staff identity, or whoever opened the
  -- ticket if the caller is an owner-only account (payment.taken_by is NOT NULL).
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

  -- 11. Commission: resolve the rate per line, freeze it on the line, write the ledger.
  for v_line in
    select l.id, l.line_type, l.line_total, l.performer_staff_id,
           s.commission_rate, s.product_commission_rate,
           p.commission_eligible
    from public.ticket_line l
    join public.staff s on s.id = l.performer_staff_id
    left join public.product p on p.id = l.product_id
    where l.ticket_id = p_ticket_id
  loop
    if v_line.line_type = 'service' then
      v_rate := v_line.commission_rate;
    elsif v_line.commission_eligible and v_line.product_commission_rate is not null then
      v_rate := v_line.product_commission_rate;
    else
      v_rate := 0;
    end if;

    v_amount := round(v_line.line_total * v_rate / 100, 2);

    update public.ticket_line
       set commission_rate_snapshot = v_rate,
           commission_amount        = v_amount
     where id = v_line.id;

    insert into public.commission_entry(
      staff_id, ticket_id, ticket_line_id, line_type,
      base_amount, rate, amount, is_reversal)
    values (
      v_line.performer_staff_id, p_ticket_id, v_line.id, v_line.line_type,
      v_line.line_total, v_rate, v_amount, false);
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
     set status         = 'paid',
         subtotal       = v_subtotal,
         discount_total = v_discount,
         total          = v_total,
         paid_tx        = p_client_tx,
         closed_at      = now()
   where id = p_ticket_id;

  -- 14. Receipt payload (no second round-trip; no rate/commission leak).
  return public._pay_ticket_result(p_ticket_id);
end;
$$;

revoke all on function public.pay_ticket(uuid, jsonb, jsonb, uuid) from public;
grant execute on function public.pay_ticket(uuid, jsonb, jsonb, uuid) to authenticated;
