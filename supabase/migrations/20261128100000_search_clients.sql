-- M16 — search_clients(term): front-desk client search exposed as an RPC so the search
-- term travels in the POST body, not the GET query string (no client PII in request
-- URLs; the previous `.from('client').or(...)` put the name/phone in the URL).
--
-- SECURITY INVOKER: the existing client RLS (client_staff_all / client_self_read) still
-- decides which rows a caller can see — this only moves the filtering server-side and
-- keeps the projection minimal (id, name, phone — never notes / email / loyalty).
-- search_path='' + schema-qualified, per the money-fn convention.

create or replace function public.search_clients(term text)
returns table (id uuid, name text, phone text)
language sql
stable
security invoker
set search_path = ''
as $$
  with q as (
    select
      btrim(coalesce(term, ''))                             as t,
      regexp_replace(coalesce(term, ''), '[^0-9]', '', 'g') as digits
  )
  select c.id, c.name, c.phone
  from public.client c, q
  where
    q.t = ''  -- empty term → the first 20 clients by name
    -- name: LIKE wildcards in the term are escaped so they match literally (the term
    -- is a bind parameter, so there is no filter-grammar injection surface either).
    or c.name ilike '%' || replace(replace(replace(q.t, '\', '\\'), '%', '\%'), '_', '\_') || '%'
    -- phone: compare digits-only against the stored normalized phone (format-agnostic).
    or (q.digits <> '' and c.phone_norm like '%' || q.digits || '%')
  order by c.name
  limit 20;
$$;

comment on function public.search_clients(text) is
  'Front-desk client search by name or phone. Term travels in the POST body (no PII in '
  'URLs); returns id/name/phone only; which rows are visible is governed by client RLS.';

-- Signed-in users only (anon never); RLS still decides which rows they actually get.
revoke all on function public.search_clients(text) from public;
grant execute on function public.search_clients(text) to authenticated;
