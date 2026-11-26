-- pgTAP · migración 0209 (backend-supabase#317, seguimiento de docs-organizacion#191; decisión del 26/11, opción 1):
-- `campania_coordinador` baja COMPLETA en cada pull, para que vuelvan los coordinadores que la política de la 0178 escondía
-- cuando el delta pasó por encima de su fila. Ana (b1) está inscripta en la campaña e1.
--   · (a) a Cesar (c2) lo suman con un rol que empieza más tarde (`valido_desde`): cuando el rol empieza, su fila no
--     cambia y el delta no la trae; el pull siguiente sí;
--   · (b) c3 está suspendido, lo quitan de la campaña (`deleted_at`) y después lo reactivan: el pull trae la fila con
--     `deleted_at` (la baja que se había perdido);
--   · (c) a c4 le cambian el nombre mientras estaba escondido (rol que no empezó): el pull trae el nombre nuevo;
--   · la RLS no cambia: lo que sigue escondido (c5, rol vencido) no baja, ni el de otra campaña (c6);
--   · la entidad sola en un pull no escribe en `sync.log` (no cuenta como novedad); junto a otra entidad, `filas` no la suma;
--   · paginación: con `p_limite` menor que las filas, la página cortada devuelve `sigue: true` y la siguiente la continúa
--     sin repetir ni perder filas; el watermark de un pull terminado (o uno de antes de la 0209, sin `sigue`) arranca de cero.
--
-- Como 0178 y 0200, NO va en una transacción: el delta solo sirve lo commiteado. Limpia al empezar y al final.

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

-- Ids con el prefijo 209: usuarios 209b1.., campañas 209e1 y 209e2, filas de campania_coordinador 209f2..
create or replace function pg_temp.u(p_sufijo text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000209' || p_sufijo)::uuid;
$$;

create or replace function pg_temp.limpiar() returns void language plpgsql as $$
begin
  delete from public.campania_coordinador where campania_id in (pg_temp.u('e1'), pg_temp.u('e2'));
  delete from public.campania_colportor where campania_id in (pg_temp.u('e1'), pg_temp.u('e2'));
  delete from public.campania where id in (pg_temp.u('e1'), pg_temp.u('e2'));
  delete from public.usuario_rol
   where usuario_id in (select pg_temp.u(s) from unnest(array['b1','c1','c2','c3','c4','c5','c6']) s);
  delete from auth.users
   where id in (select pg_temp.u(s) from unnest(array['b1','c1','c2','c3','c4','c5','c6']) s);
end $$;

-- Los sufijos de los usuarios de las filas que bajaron (con un * si bajaron como baja), ordenados.
create or replace function pg_temp.bajaron(p_delta jsonb) returns text[] language sql as $$
  select coalesce(array_agg(right(e ->> 'usuario_id', 2) || case when e ->> 'deleted_at' is not null then '*' else '' end
                            order by e ->> 'usuario_id'), array[]::text[])
    from jsonb_array_elements(coalesce(p_delta -> 'rows' -> 'campania_coordinador', '[]'::jsonb)) e;
$$;

-- Lo que Ana pide en cada pull: solo la entidad.
create or replace function pg_temp.pull(p_watermark jsonb, p_limite integer default 1000) returns jsonb language sql as $$
  select sync.pull(array['campania_coordinador'], p_watermark, p_limite);
$$;

-- ---------------------------------------------------------------------------
-- Fixtures (como postgres). e1: coordinan c1 (el espejo de la columna), c2, c3, c4 y c5; e2: coordina c6. Ana (b1) está
-- inscripta en e1. c2 y c4 tienen el rol de coordinador desde mañana; a c5 se le venció ayer; el resto, vigente.
-- ---------------------------------------------------------------------------
select pg_temp.limpiar();
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at,
                        raw_user_meta_data)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'completo209-' || s || '@example.com', 'x', now(), now(), now(),
       jsonb_build_object('nombre', 'Nom' || s, 'apellido', 'Ape' || s)
  from unnest(array['b1','c1','c2','c3','c4','c5','c6']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('c1','COORDINADOR'), ('c3','COORDINADOR'), ('c6','COORDINADOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.usuario_rol (usuario_id, rol_id, valido_desde)
select pg_temp.u(x.s), r.id, now() + interval '1 day'
  from (values ('c2'), ('c4')) x(s) join public.rol r on r.codigo = 'COORDINADOR';
insert into public.usuario_rol (usuario_id, rol_id, valido_desde, valido_hasta)
select pg_temp.u('c5'), r.id, now() - interval '10 days', now() - interval '1 day'
  from public.rol r where r.codigo = 'COORDINADOR';
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'e1 completo209', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('c1')),
  (pg_temp.u('e2'), 'e2 completo209', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('c6'));
insert into public.campania_coordinador (id, campania_id, usuario_id) values
  (pg_temp.u('f2'), pg_temp.u('e1'), pg_temp.u('c2')),
  (pg_temp.u('f3'), pg_temp.u('e1'), pg_temp.u('c3')),
  (pg_temp.u('f4'), pg_temp.u('e1'), pg_temp.u('c4')),
  (pg_temp.u('f5'), pg_temp.u('e1'), pg_temp.u('c5'));
insert into public.campania_colportor (campania_id, usuario_id) values (pg_temp.u('e1'), pg_temp.u('b1'));

-- ---------------------------------------------------------------------------
-- 1. El pull inicial: Ana baja solo a los vigentes (la RLS no cambió)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table p1 as select pg_temp.pull('{}'::jsonb) as d;
select is(pg_temp.bajaron(d), array['c1','c3'],
          'pull inicial: Ana baja a c1 y c3; no a c2 ni c4 (el rol empieza mañana), ni a c5 (vencido), ni a c6 (otra campaña)') from p1;
select ok(not ((d -> 'watermark' -> 'campania_coordinador') ? 'sigue'), 'el pull terminó: el watermark no lleva `sigue`') from p1;

-- ---------------------------------------------------------------------------
-- 2. Mientras tanto, en el servidor: c3 se suspende y lo quitan de e1; a c4 le cambian el nombre. Las tres filas escondidas
--    cambian detrás del cursor de Ana.
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
update public.usuario set suspendido_en = now() where id = pg_temp.u('c3');
update public.campania_coordinador set deleted_at = now() where id = pg_temp.u('f3');
update public.usuario set nombre = 'NombreNuevo209' where id = pg_temp.u('c4');

select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table p2 as select pg_temp.pull((select d -> 'watermark' from p1)) as d;
select is(pg_temp.bajaron(d), array['c1'], 'el pull siguiente: c3 suspendido y c4 escondido no bajan (la RLS sigue igual)') from p2;
select ok(not ((d -> 'watermark' -> 'campania_coordinador') ? 'sigue'), 'y el watermark sigue sin `sigue`') from p2;

-- ---------------------------------------------------------------------------
-- 3. Los tres casos: el rol de c2 y c4 empieza (ninguna fila cambia) y c3 se reactiva (su fila ya cambió antes del cursor)
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
update public.usuario_rol set valido_desde = clock_timestamp() - interval '1 second'
 where usuario_id in (pg_temp.u('c2'), pg_temp.u('c4'));
update public.usuario set suspendido_en = null where id = pg_temp.u('c3');

select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table p3 as select pg_temp.pull((select d -> 'watermark' from p2)) as d;
select is(pg_temp.bajaron(d), array['c1','c2','c3*','c4'],
          '(a) c2 baja cuando le empieza el rol; (b) c3 baja como BAJA (deleted_at) al reactivarse; (c) c4 baja; más c1, la de siempre') from p3;
select is((select e ->> 'nombre' from p3, jsonb_array_elements(d -> 'rows' -> 'campania_coordinador') e
            where e ->> 'usuario_id' = pg_temp.u('c4')::text),
          'NombreNuevo209', '(c) c4 baja con el nombre nuevo, el que cambió mientras estaba escondido') from p3;
select ok((select e ->> 'deleted_at' is not null from p3, jsonb_array_elements(d -> 'rows' -> 'campania_coordinador') e
            where e ->> 'usuario_id' = pg_temp.u('c3')::text),
          '(b) la fila de c3 trae su deleted_at') from p3;
select ok(not ((d -> 'watermark' -> 'campania_coordinador') ? 'sigue'), 'el watermark no lleva `sigue`') from p3;

-- Lo que viaja es lo mismo que desde cero, y repetirlo da lo mismo (completo en cada pull).
select is(pg_temp.bajaron(pg_temp.pull((select d -> 'watermark' from p3))), array['c1','c2','c3*','c4'],
          'otro pull con el watermark del anterior: las mismas filas (completo en cada pull)');
select is(pg_temp.bajaron(pg_temp.pull('{}'::jsonb)), array['c1','c2','c3*','c4'], 'y un pull desde cero, también');
select is((select count(*)::int from jsonb_array_elements(pg_temp.pull('{}'::jsonb) -> 'rows' -> 'campania_coordinador') e
            where e ? 'xmin_w'), 0, 'las filas no traen la maquinaria del delta');

-- Un watermark de antes de la 0209 (con cursor y sin `sigue`): también arranca de cero, no se pierde nada.
select is(pg_temp.bajaron(pg_temp.pull(jsonb_build_object('campania_coordinador',
            jsonb_build_object('xid', '99999999999', 'id', 'ffffffff-ffff-ffff-ffff-ffffffffffff', 'area', 'x')))),
          array['c1','c2','c3*','c4'], 'un watermark viejo, con cursor adelante y sin `sigue`, baja todo igual');

-- La RLS sigue igual: a c5 (vencido) y c6 (otra campaña) no se los ve, y la clave del aviso (0200) viene.
select is((select array_agg(right(e #>> '{}', 2) order by e #>> '{}')
             from jsonb_array_elements(pg_temp.pull('{}'::jsonb) -> 'out_of_area' -> 'campania_coordinador') e),
          array['f5'], 'el aviso de la 0200 sigue igual: solo c5 (rol vencido) va en out_of_area; c6 es de otra campaña');

-- ---------------------------------------------------------------------------
-- 4. Un pull que solo trae la entidad no es una novedad: no escribe en sync.log
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
create temp table log0 as select count(*)::int as n from sync.log where operacion = 'pull';
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(jsonb_array_length(pg_temp.pull('{}'::jsonb) -> 'rows' -> 'campania_coordinador'), 4, 'el pull trae las cuatro filas');
select pg_temp.como_servidor();
select is((select count(*)::int from sync.log where operacion = 'pull'), (select n from log0),
          'y no escribió nada en sync.log: lo que baja completo no es una novedad');

-- Junto a otra entidad con novedades: se registra, y `filas` suma las de la otra, no las de campania_coordinador.
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table pj as select sync.pull(array['campania_coordinador', 'campania'], '{}'::jsonb, 1000) as d;
select pg_temp.como_servidor();
select is((select count(*)::int from sync.log where operacion = 'pull'), (select n + 1 from log0),
          'con otra entidad en el pull sí se registra');
select is((select l.filas from sync.log l where l.operacion = 'pull' order by l.id desc limit 1),
          (select jsonb_array_length(d -> 'rows' -> 'campania') from pj),
          '`filas` cuenta solo las de la otra entidad') ;

-- ---------------------------------------------------------------------------
-- 5. Paginación: p_limite 3 con 4 filas. La página cortada lleva `sigue`; la siguiente la continúa sin repetir ni perder
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table g1 as select pg_temp.pull('{}'::jsonb, 3) as d;
select is(cardinality(pg_temp.bajaron(d)), 3, 'primera página: 3 filas') from g1;
select is((d ->> 'has_more')::boolean, true, 'y hay más') from g1;
select is((d -> 'watermark' -> 'campania_coordinador' ->> 'sigue')::boolean, true, 'el watermark de la página cortada lleva `sigue: true`') from g1;
create temp table g2 as select pg_temp.pull((select d -> 'watermark' from g1), 3) as d;
select is(cardinality(pg_temp.bajaron(d)), 1, 'segunda página: la fila que faltaba, sin repetir las de la primera') from g2;
select is((d ->> 'has_more')::boolean, false, 'y ya no hay más') from g2;
select ok(not ((d -> 'watermark' -> 'campania_coordinador') ? 'sigue'), 'el watermark final no lleva `sigue`') from g2;
select is((select array_agg(x order by x) from (select unnest(pg_temp.bajaron(g1.d) || pg_temp.bajaron(g2.d)) x from g1, g2) s),
          array['c1','c2','c3*','c4'], 'las dos páginas juntas son las cuatro filas, una vez cada una') ;
-- Un pull nuevo, con el watermark final, vuelve a bajar todo desde la primera página.
select is(cardinality(pg_temp.bajaron(pg_temp.pull((select d -> 'watermark' from g2), 3))), 3,
          'con el watermark de un pull terminado, el pull siguiente arranca de cero (otra vez 3 en la primera página)');

-- ---------------------------------------------------------------------------
-- Limpieza
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
drop table p1, p2, p3, pj, log0, g1, g2;
select pg_temp.limpiar();
select is((select count(*)::int from public.campania_coordinador
            where campania_id in (pg_temp.u('e1'), pg_temp.u('e2'))), 0, 'limpieza: no queda nada de la prueba');

select * from finish();
