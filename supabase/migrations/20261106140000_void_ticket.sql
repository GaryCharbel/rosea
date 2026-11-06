-- Phase 3.2 — void_ticket: owner-only, idempotent, ledger-style reversal of a PAID
-- ticket (design §7.2). Never deletes: it posts compensating rows so the history is
-- auditable. For every earning commission entry it writes a negative is_reversal entry
-- (net 0 per staff); it mirrors each payment and tip with a negative row; it restocks
-- each sold unit with a 'void_restore' movement; and it flips paid -> void. SECURITY
-- DEFINER (sole writer of the RPC-only money tables), search_path='', schema-qualified.
--
-- Idempotent via ticket.void_tx (a re-call with the same client_tx is a no-op). Raises:
--   P0001 = not found / not paid / already voided
--   insufficient_privilege (42501) = caller is not an owner
create or replace function public.void_ticket(
  p_ticket_id uuid,
  p_reason    text default null,
  p_client_tx uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ticket   public.ticket;
  v_taken_by uuid;
  v_rec      record;
begin
  -- 1. Authz: owner only (voiding reverses money — stricter than taking payment).
  if not private.is_owner() then
    raise exception 'Only an owner can void a ticket.'
      using errcode = 'insufficient_privilege';
  end if;

  -- 2. Shape.
  if p_client_tx is null then
    raise exception 'Missing the void transaction id. Retry the void from the POS.'
      using errcode = 'P0002';
  end if;

  -- 3. Advisory lock (same key as pay_ticket: serialize all money ops on this ticket).
  perform pg_advisory_xact_lock(hashtextextended(p_ticket_id::text, 0));

  -- 4. Load + lock.
  select * into v_ticket from public.ticket where id = p_ticket_id for update;
  if not found then
    raise exception 'That ticket no longer exists. Refresh the POS.'
      using errcode = 'P0001';
  end if;

  -- 5. Idempotent replay / state guard.
  if v_ticket.status = 'void' then
    if v_ticket.void_tx = p_client_tx then
      return public._pay_ticket_result(p_ticket_id);   -- exact replay: no-op
    end if;
    raise exception 'This ticket is already voided.'
      using errcode = 'P0001';
  elsif v_ticket.status <> 'paid' then
    raise exception 'Only a paid ticket can be voided. An open ticket is discarded, not voided.'
      using errcode = 'P0001';
  end if;

  -- Owner accounts have no staff_id; attribute the reversal rows to whoever opened it.
  v_taken_by := coalesce(private.current_staff_id(), v_ticket.opened_by);

  -- 6. Reverse commission: one negative is_reversal entry per earning entry (net 0).
  --    round(-base*rate/100,2) = -round(base*rate/100,2), so commission_amount_chk holds.
  insert into public.commission_entry(
    staff_id, ticket_id, ticket_line_id, line_type, base_amount, rate, amount, is_reversal)
  select staff_id, ticket_id, ticket_line_id, line_type, -base_amount, rate, -amount, true
  from public.commission_entry
  where ticket_id = p_ticket_id and not is_reversal;

  -- 7. Reverse payments and tips (mirror each original positive row with a negative).
  insert into public.payment(ticket_id, method, amount, reference, taken_by, client_tx)
  select ticket_id, method, -amount, reference, v_taken_by, p_client_tx
  from public.payment
  where ticket_id = p_ticket_id and amount > 0;

  insert into public.tip(ticket_id, staff_id, amount, method, client_tx)
  select ticket_id, staff_id, -amount, method, p_client_tx
  from public.tip
  where ticket_id = p_ticket_id and amount > 0;

  -- 8. Restock: a 'void_restore' (+units) for each 'sale' movement, and bump the product.
  for v_rec in
    select product_id, -qty_delta as restore_qty
    from public.stock_movement
    where ticket_id = p_ticket_id and reason = 'sale'
  loop
    update public.product
       set stock_quantity = stock_quantity + v_rec.restore_qty
     where id = v_rec.product_id;
    insert into public.stock_movement(product_id, reason, qty_delta, ticket_id, created_by)
    values (v_rec.product_id, 'void_restore', v_rec.restore_qty, p_ticket_id,
            private.current_staff_id());
  end loop;

  -- 9. Flip paid -> void (record the reason on the ticket note).
  update public.ticket
     set status  = 'void',
         void_tx = p_client_tx,
         note    = case when p_reason is null then note
                        else coalesce(note || E'\n', '') || 'VOID: ' || p_reason end
   where id = p_ticket_id;

  return public._pay_ticket_result(p_ticket_id);
end;
$$;

revoke all on function public.void_ticket(uuid, text, uuid) from public;
grant execute on function public.void_ticket(uuid, text, uuid) to authenticated;
