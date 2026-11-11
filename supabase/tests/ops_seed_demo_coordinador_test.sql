-- pgTAP · supabase/seed-demo/sumar-coordinador-demo.sql: coordinador.demo pasa a coordinar las campañas de la demo.
--   1. Sin la cuenta coordinador.demo no hace nada ni falla (la base local y CI no la tienen).
--   2. Con ella, suma una fila de campania_coordinador por campaña viva de la demo (prefijo 5eed0000-0000-7000-8003-);
--      el coordinador generado sigue y campania.coordinador_id no cambia; otras campañas no se tocan.
--   3. coordinador.demo ve la campaña de la demo en campanias_del_coordinador() (lo que lee el panel).
--   4. Correrlo dos veces no agrega nada.
-- El script se carga con \i, tal como lo corre scripts/db-seed-demo.sh. Va en una transacción que se deshace.
-- Requiere invocarse con cwd = raíz del repo (así lo hace scripts/db-test.sh).
begin;
select * from no_plan();

create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000251' || p)::uuid;
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- a1 coordinador generado de la demo, a2 coordinador.demo, a3 otra cuenta coordinadora.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(x.s), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', x.mail, 'x', now(), now(), now()
  from (values ('a1', 'demo.generado.t251@example.com'), ('a3', 'otro.coordinador.t251@example.com')) x(s, mail);
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id from (values ('a1'), ('a3')) x(s) join public.rol r on r.codigo = 'COORDINADOR';

-- Campañas de la demo (con el id del generador) y una que no es de la demo.
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id)
values ('5eed0000-0000-7000-8003-000000000001', 'Verano t251', 'VERANO', public.hoy_montevideo() - 30, public.hoy_montevideo() + 90, pg_temp.u('a1')),
       ('5eed0000-0000-7000-8003-000000000002', 'Invierno t251', 'INVIERNO', public.hoy_montevideo() - 120, public.hoy_montevideo() - 60, pg_temp.u('a1')),
       (pg_temp.u('b1'), 'Otra t251', 'VERANO', public.hoy_montevideo() - 30, public.hoy_montevideo() + 90, pg_temp.u('a3'));

create temp table antes as
  select c.id, c.coordinador_id, c.sync_version from public.campania c
   where c.id in ('5eed0000-0000-7000-8003-000000000001', '5eed0000-0000-7000-8003-000000000002', pg_temp.u('b1'));

-- 1. Sin coordinador.demo: no hace nada
\o /dev/null
\i supabase/seed-demo/sumar-coordinador-demo.sql
\o
select is((select count(*) from public.campania_coordinador cc
            where cc.campania_id::text like '5eed0000-0000-7000-8003-%' and cc.deleted_at is null),
          2::bigint, 'sin coordinador.demo cada campaña de la demo sigue con su único coordinador');

-- 2. Con coordinador.demo
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
values (pg_temp.u('a2'), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        'coordinador.demo@example.com', 'x', now(), now(), now());
insert into public.usuario_rol (usuario_id, rol_id) select pg_temp.u('a2'), r.id from public.rol r where r.codigo = 'COORDINADOR';

\o /dev/null
\i supabase/seed-demo/sumar-coordinador-demo.sql
\o
select is((select count(*) from public.campania_coordinador cc
            where cc.usuario_id = pg_temp.u('a2') and cc.deleted_at is null and cc.campania_id::text like '5eed0000-0000-7000-8003-%'),
          2::bigint, 'coordinador.demo coordina las dos campañas de la demo');
select is((select count(*) from public.campania_coordinador cc
            where cc.usuario_id = pg_temp.u('a1') and cc.deleted_at is null),
          2::bigint, 'el coordinador generado sigue en las dos');
select is((select count(*) from public.campania c join antes a on a.id = c.id
            where c.coordinador_id is distinct from a.coordinador_id or c.sync_version <> a.sync_version),
          0::bigint, 'ninguna campaña cambia (ni coordinador_id ni sync_version)');
select is((select count(*) from public.campania_coordinador cc where cc.campania_id = pg_temp.u('b1') and cc.deleted_at is null),
          1::bigint, 'una campaña que no es de la demo no se toca');

-- 3. Lo que lee el panel con la sesión de coordinador.demo (la de invierno ya terminó: no se lista)
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.u('a2'), 'role', 'authenticated')::text, true),
       set_config('request.jwt.claim.sub', pg_temp.u('a2')::text, true),
       set_config('request.jwt.claim.role', 'authenticated', true);
select results_eq(
  $$ select id from public.campanias_del_coordinador() $$,
  $$ values ('5eed0000-0000-7000-8003-000000000001'::uuid) $$,
  'coordinador.demo ve la campaña en curso de la demo');
reset role;

-- 4. Idempotente
\o /dev/null
\i supabase/seed-demo/sumar-coordinador-demo.sql
\o
select is((select count(*) from public.campania_coordinador cc where cc.usuario_id = pg_temp.u('a2')),
          2::bigint, 'una segunda corrida no agrega nada');

select * from finish();
rollback;
