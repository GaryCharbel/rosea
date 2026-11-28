-- pgTAP — M16 search_clients(term). Runs as postgres (RLS bypassed), so this proves the
-- search + projection logic; role-based row visibility is covered by the RLS suite.
begin;
select plan(7);

select has_function('public', 'search_clients', array['text'], 'search_clients(text) exists');
select is(
  (select security_type from information_schema.routines
     where routine_schema = 'public' and routine_name = 'search_clients'),
  'INVOKER', 'search_clients runs as INVOKER, so client RLS still applies');

-- fixtures (one name carries a literal % to prove wildcard escaping)
insert into public.client (name, phone) values
  ('Rania Abou Jaoude', '03-111222'),
  ('Randa Khalil',      '70 118 204'),
  ('Maya 50% Off',      null);

select is((select count(*) from public.search_clients('rania')), 1::bigint,
  'matches by name, case-insensitive');
select is((select count(*) from public.search_clients('118')), 1::bigint,
  'matches by phone digits regardless of formatting');
select is((select name from public.search_clients('70118')), 'Randa Khalil',
  'phone-digit match returns the right client');
select ok((select count(*) from public.search_clients('')) >= 3,
  'an empty term returns the client list');
select is((select count(*) from public.search_clients('_')), 0::bigint,
  'a lone _ is treated literally (wildcards escaped), matching nothing');

select * from finish();
rollback;
