-- pgTAP · buscar_candidatos() (0015, backend-supabase#41): cuentas con el mismo nombre completo a
-- los dos lados del corte de página. El cursor (p_despues_de) es el id de la última fila de la
-- página anterior, y el orden desempata por id: ni se repiten ni se saltean cuentas.
begin;
select * from no_plan();

create or replace function pg_temp.actuar_como(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('role', 'authenticated', true);
end $$;
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000025' || p)::uuid;
$$;

-- a1 coordina la campaña e1. 13 cuentas «Igualdo Repetido» (que empiezan con el texto: el corte de
-- la página 1 cae en medio del empate) y 3 «Zeta Igualdo» (que solo lo contienen, también
-- iguales entre sí).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at,
                        raw_user_meta_data, created_at, updated_at)
select pg_temp.u(x.s), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       x.email, 'x', now(), jsonb_build_object('nombre', x.n, 'apellido', x.a), now(), now()
  from (
    select 'a1' as s, 'coord@empates25.test' as email, '' as n, '' as a
    union all
    select 'c' || to_hex(i), 'e25-' || i || '@empates25.test', 'Igualdo', 'Repetido'
      from generate_series(1, 13) i
    union all
    select 'd' || i, 'z25-' || i || '@empates25.test', 'Zeta', 'Igualdo'
      from generate_series(1, 3) i
  ) x;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u('a1'), r.id from public.rol r where r.codigo = 'COORDINADOR';
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id)
values (pg_temp.u('e1'), 'Verano empates', 'VERANO', current_date - 10, current_date + 30, pg_temp.u('a1'));

select pg_temp.actuar_como(pg_temp.u('a1'));
create temp table pag_1 on commit drop as
select row_number() over () as n, c.usuario_id from public.buscar_candidatos(pg_temp.u('e1'), 'igualdo') c;
create temp table pag_2 on commit drop as
select row_number() over () as n, c.usuario_id
  from public.buscar_candidatos(pg_temp.u('e1'), 'igualdo', (select usuario_id from pag_1 where n = 10)) c;
create temp table pag_3 on commit drop as
select row_number() over () as n, c.usuario_id
  from public.buscar_candidatos(pg_temp.u('e1'), 'igualdo', (select usuario_id from pag_2 where n = 6)) c;
create temp table esperado on commit drop as
select row_number() over () as n, x.id
  from (select pg_temp.u('c' || to_hex(i)) as id from generate_series(1, 13) i order by 1) x
 union all
select 13 + row_number() over (), y.id
  from (select pg_temp.u('d' || i) as id from generate_series(1, 3) i order by 1) y;
grant select on pag_1, pag_2, pag_3, esperado to authenticated;

select is((select count(*) from pag_1), 10::bigint, 'página 1: 10 cuentas, todas con el mismo nombre');
select is((select count(*) from pag_2), 6::bigint, 'página 2: las 3 que faltan del empate y las 3 que solo contienen el texto');
select is((select count(*) from pag_3), 0::bigint, 'después de la última, nada');
select results_eq(
  $$ select usuario_id from (select n, usuario_id from pag_1 union all select 10 + n, usuario_id from pag_2) t order by n $$,
  $$ select id from esperado order by n $$,
  'las 16 cuentas salen una vez cada una, en el orden (empiezan con el texto, y dentro del empate por id)');

select * from finish();
rollback;
