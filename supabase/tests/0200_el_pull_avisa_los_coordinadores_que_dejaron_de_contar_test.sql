-- pgTAP · migración 0200 (backend-supabase#249, hallazgo bloqueante de la revisión del PR 296; decisión del 22/11, P1):
-- el teléfono se entera por el pull de que un coordinador de su campaña dejó de contar en «¿Quién te acompaña?».
--   · Ana sincroniza con todos los coordinadores vigentes; después, en el servidor, a uno lo suspenden, a otro le dan de baja
--     la cuenta, a otro le quitan el rol y a otro se le vence (`valido_hasta`, sin que cambie ninguna fila). En el delta
--     siguiente los cuatro llegan en `out_of_area` de `campania_coordinador` (antes no llegaba nada);
--   · el que se quita de la campaña (fila dada de baja) baja por el delta como baja; si además dejó de contar, la política
--     esconde la baja y va en el aviso;
--   · el administrador que figura en la campaña y nunca fue coordinador se avisa desde el primer pull;
--   · repetir el pull da lo mismo (idempotente), con delta o desde cero; un coordinador de otra campaña no se avisa nunca;
--   · quien igual ve las filas (el coordinador de la campaña, el ADMIN) no recibe aviso;
--   · el aviso son solo ids de fila, y el helper no se llama sin sesión.
--
-- Como 0178, NO va en una transacción: el delta solo sirve lo commiteado. Limpia al empezar y al final.

select * from no_plan();

create or replace function pg_temp.actuar_como(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, false);
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('role', 'authenticated', false);
end $$;

create or replace function pg_temp.como_servidor() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', false);
  perform set_config('request.jwt.claims', '', false);
  perform set_config('request.jwt.claim.sub', '', false);
end $$;

create or replace function pg_temp.como_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', false);
  perform set_config('request.jwt.claim.sub', '', false);
  perform set_config('role', 'anon', false);
end $$;

-- Ids con el prefijo 200: usuarios 200b1.., campañas 200e1 y 200e2, filas de campania_coordinador 200f2.. (la f del
-- coordinador cN es fN; la del administrador, fa).
create or replace function pg_temp.u(p_sufijo text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000200' || p_sufijo)::uuid;
$$;

create or replace function pg_temp.limpiar() returns void language plpgsql as $$
begin
  delete from public.campania_coordinador where campania_id in (pg_temp.u('e1'), pg_temp.u('e2'));
  delete from public.campania_colportor where campania_id in (pg_temp.u('e1'), pg_temp.u('e2'));
  delete from public.campania where id in (pg_temp.u('e1'), pg_temp.u('e2'));
  delete from public.usuario_rol
   where usuario_id in (select pg_temp.u(s) from unnest(array['b1','c1','c2','c3','c4','c5','c6','c7','c8','c9','ad']) s);
  delete from auth.users
   where id in (select pg_temp.u(s) from unnest(array['b1','c1','c2','c3','c4','c5','c6','c7','c8','c9','ad']) s);
end $$;

-- Los sufijos de los usuarios de las filas que bajaron (con un * si bajaron como baja), ordenados.
create or replace function pg_temp.bajaron(p_delta jsonb) returns text[] language sql as $$
  select coalesce(array_agg(right(e ->> 'usuario_id', 2) || case when e ->> 'deleted_at' is not null then '*' else '' end
                            order by e ->> 'usuario_id'), array[]::text[])
    from jsonb_array_elements(coalesce(p_delta -> 'rows' -> 'campania_coordinador', '[]'::jsonb)) e;
$$;
-- Los sufijos de las filas avisadas en out_of_area de campania_coordinador, ordenados.
create or replace function pg_temp.avisados(p_delta jsonb) returns text[] language sql as $$
  select coalesce(array_agg(right(e #>> '{}', 2) order by e #>> '{}'), array[]::text[])
    from jsonb_array_elements(coalesce(p_delta -> 'out_of_area' -> 'campania_coordinador', '[]'::jsonb)) e;
$$;

-- ---------------------------------------------------------------------------
-- Fixtures (como postgres). e1: coordinan c1 (el espejo de la columna), c2 a c7 y el ADMIN ad (que no coordina por
-- rol); e2: coordinan c8 y c9. Ana (b1) está inscripta en e1. c4 tiene el rol de coordinador hasta dentro de 3 segundos.
-- ---------------------------------------------------------------------------
select pg_temp.limpiar();
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at,
                        raw_user_meta_data)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'aviso200-' || s || '@example.com', 'x', now(), now(), now(),
       jsonb_build_object('nombre', 'Nom' || s, 'apellido', 'Ape' || s)
  from unnest(array['b1','c1','c2','c3','c4','c5','c6','c7','c8','c9','ad']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('c1','COORDINADOR'), ('c2','COORDINADOR'), ('c3','COORDINADOR'),
               ('c5','COORDINADOR'), ('c6','COORDINADOR'), ('c7','COORDINADOR'), ('c8','COORDINADOR'),
               ('c9','COORDINADOR'), ('ad','ADMIN')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.usuario_rol (usuario_id, rol_id, valido_desde, valido_hasta)
select pg_temp.u('c4'), r.id, now() - interval '10 days', clock_timestamp() + interval '3 seconds'
  from public.rol r where r.codigo = 'COORDINADOR';
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'e1 aviso200', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('c1')),
  (pg_temp.u('e2'), 'e2 aviso200', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('c9'));
insert into public.campania_coordinador (id, campania_id, usuario_id) values
  (pg_temp.u('f2'), pg_temp.u('e1'), pg_temp.u('c2')),
  (pg_temp.u('f3'), pg_temp.u('e1'), pg_temp.u('c3')),
  (pg_temp.u('f4'), pg_temp.u('e1'), pg_temp.u('c4')),
  (pg_temp.u('f5'), pg_temp.u('e1'), pg_temp.u('c5')),
  (pg_temp.u('f6'), pg_temp.u('e1'), pg_temp.u('c6')),
  (pg_temp.u('f7'), pg_temp.u('e1'), pg_temp.u('c7')),
  (pg_temp.u('fa'), pg_temp.u('e1'), pg_temp.u('ad')),
  (pg_temp.u('f8'), pg_temp.u('e2'), pg_temp.u('c8'));
insert into public.campania_colportor (campania_id, usuario_id) values (pg_temp.u('e1'), pg_temp.u('b1'));

-- ---------------------------------------------------------------------------
-- 1. El registro: el helper es DEFINER, sin parámetros, solo ids, y no lo llama anon
-- ---------------------------------------------------------------------------
select is((select p.prosecdef from pg_proc p
            where p.oid = 'public.coordinadores_que_no_cuentan_en_mis_campanias()'::regprocedure),
          true, 'el helper es SECURITY DEFINER');
select is((select format_type(p.prorettype, null) || case when p.proretset then ' setof' else '' end from pg_proc p
            where p.oid = 'public.coordinadores_que_no_cuentan_en_mis_campanias()'::regprocedure),
          'uuid setof', 'y devuelve solo ids');
select is(has_function_privilege('anon', 'public.coordinadores_que_no_cuentan_en_mis_campanias()', 'execute'), false,
          'anon no lo puede llamar');
select is(has_function_privilege('authenticated', 'public.coordinadores_que_no_cuentan_en_mis_campanias()', 'execute'),
          true, 'authenticated sí (sync.pull es INVOKER)');

-- ---------------------------------------------------------------------------
-- 2. El pull inicial: Ana baja a todos los vigentes; el administrador se avisa desde el principio
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table p1 as select sync.pull(array['campania_coordinador'], '{}'::jsonb, 1000) as d;
select is(pg_temp.bajaron(d), array['c1','c2','c3','c4','c5','c6','c7'],
          'pull inicial: Ana baja a los siete coordinadores de e1 (c4 todavía tiene el rol)') from p1;
select is(pg_temp.avisados(d), array['fa'],
          'y en out_of_area va la fila del administrador que figura en e1 y no es coordinador') from p1;
select is(jsonb_typeof(d -> 'out_of_area' -> 'campania_coordinador' -> 0), 'string',
          'el aviso son ids sueltos, sin nombre ni persona') from p1;

-- El coordinador de e1 (no inscripto) y el ADMIN ven las filas: no reciben aviso.
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(sync.pull(array['campania_coordinador'], '{}'::jsonb, 1000) -> 'out_of_area', null,
          'el coordinador de la campaña ve a todos sus colegas: sin out_of_area');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(sync.pull(array['campania_coordinador'], '{}'::jsonb, 1000) -> 'out_of_area', null,
          'el ADMIN ve todo: sin out_of_area');

-- ---------------------------------------------------------------------------
-- 3. En el servidor: suspender (c2), dar de baja la cuenta (c3), quitar el rol (c5), quitar de la campaña (c6),
--    suspender y quitar de la campaña (c7), suspender al de otra campaña (c8); y a c4 se le vence el rol.
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
update public.usuario set suspendido_en = now() where id in (pg_temp.u('c2'), pg_temp.u('c7'), pg_temp.u('c8'));
update public.usuario set deleted_at = now() where id = pg_temp.u('c3');
update public.usuario_rol set deleted_at = now()
 where usuario_id = pg_temp.u('c5') and rol_id = (select id from public.rol where codigo = 'COORDINADOR');
update public.campania_coordinador set deleted_at = now() where id in (pg_temp.u('f6'), pg_temp.u('f7'));
-- El vencimiento no cambia ninguna fila: se espera a que pase la hora.
select pg_sleep(greatest(0, extract(epoch from (ur.valido_hasta - clock_timestamp()))) + 0.2)
  from public.usuario_rol ur where ur.usuario_id = pg_temp.u('c4');
select is(public.cuenta_tiene_rol(pg_temp.u('c4'), 'COORDINADOR'), false, 'a c4 ya se le venció el rol');

-- ---------------------------------------------------------------------------
-- 4. El delta: el teléfono se entera de los cuatro casos
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table p2 as select sync.pull(array['campania_coordinador'], (select d -> 'watermark' from p1), 1000) as d;
select is(pg_temp.bajaron(d), array['c6*'],
          'el delta trae como fila solo la baja de c6 (se quitó de la campaña y sigue siendo coordinador)') from p2;
select ok(pg_temp.avisados(d) @> array['f2'], 'suspendido: la fila de c2 va en out_of_area') from p2;
select ok(pg_temp.avisados(d) @> array['f3'], 'cuenta dada de baja: la de c3 también') from p2;
select ok(pg_temp.avisados(d) @> array['f4'], 'rol vencido por valido_hasta (sin cambio de fila): la de c4 también') from p2;
select ok(pg_temp.avisados(d) @> array['f5'], 'rol quitado: la de c5 también') from p2;
select is(pg_temp.avisados(d), array['f2','f3','f4','f5','f7','fa'],
          'el aviso completo: c2, c3, c4, c5, c7 (suspendido y quitado: la política le esconde la baja) y el administrador; '
          'ni c1 (vigente), ni c6 (su baja bajó como fila), ni c8 (otra campaña)') from p2;

-- Idempotente: el pull siguiente, sin cambios, repite el aviso; y desde cero, también.
create temp table p3 as select sync.pull(array['campania_coordinador'], (select d -> 'watermark' from p2), 1000) as d;
select is(pg_temp.bajaron(d), array[]::text[], 'otro delta sin cambios no baja filas') from p3;
select is(pg_temp.avisados(d), array['f2','f3','f4','f5','f7','fa'], 'y repite el mismo aviso (idempotente)') from p3;
select is(pg_temp.avisados(sync.pull(array['campania_coordinador'], '{}'::jsonb, 1000)),
          array['f2','f3','f4','f5','f7','fa'],
          'un pull desde cero también avisa: el teléfono no borra lo que ya tenía');
select is((select coalesce(array_agg(right(q.id::text, 2) order by q.id), array[]::text[])
             from public.coordinadores_que_no_cuentan_en_mis_campanias() q (id)),
          array['f2','f3','f4','f5','f7','fa'], 'el helper da lo mismo que el aviso');

-- Otra entidad en el mismo pull no se toca: la clave de campania_coordinador es la única nueva.
select is((select array_agg(k order by k)
             from jsonb_object_keys(sync.pull(array['campania_coordinador', 'campania'], '{}'::jsonb, 1000)
                                    -> 'out_of_area') k),
          array['campania_coordinador'], 'out_of_area solo trae la clave de campania_coordinador');

-- ---------------------------------------------------------------------------
-- 5. Quien no está inscripto en e1 no recibe aviso de e1; el coordinador de la campaña tampoco
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(sync.pull(array['campania_coordinador'], '{}'::jsonb, 1000) -> 'out_of_area', null,
          'el coordinador de e1 sigue sin aviso (ve las filas de sus colegas)');
select is((select count(*)::int from public.coordinadores_que_no_cuentan_en_mis_campanias()), 0,
          'y el helper le da vacío');
select pg_temp.actuar_como(pg_temp.u('c9'));
select is((select count(*)::int from public.coordinadores_que_no_cuentan_en_mis_campanias()), 0,
          'el coordinador de e2 (no inscripto en ninguna) tampoco recibe nada, ni de c8 suspendido');

select pg_temp.como_servidor();
select pg_temp.como_anon();
select throws_ok($$ select * from public.coordinadores_que_no_cuentan_en_mis_campanias() $$, '42501', null,
                 'sin sesión no se llama');

-- ---------------------------------------------------------------------------
-- Limpieza
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
drop table p1, p2, p3;
select pg_temp.limpiar();
select is((select count(*)::int from public.campania_coordinador
            where campania_id in (pg_temp.u('e1'), pg_temp.u('e2'))), 0, 'limpieza: no queda nada de la prueba');

select * from finish();
