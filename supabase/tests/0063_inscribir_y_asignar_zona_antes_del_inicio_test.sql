-- pgTAP · sumar colportores y asignar zona desde que la campaña existe (migración 0058,
-- backend-supabase#103, decisión de Cristian del 21/10, «Antes inicio»)
--   1. Una campaña por empezar admite inscribir_colportor(), buscar_candidatos(), asignar_zona() y
--      quitar_zona(); una campaña terminada, no (CI002 / CZ002, como antes). El borde: la que termina
--      hoy sí, la que terminó ayer no, la que empieza mañana sí.
--   2. Una en curso y otra por empezar a la vez, sí; dos en curso, no (CI007, R-CM02); dos por empezar,
--      no (pendiente del PR, ante la duda se bloquea). Las inscripciones dadas de baja, las de una campaña
--      terminada o borrada y las del mismo colportor en la misma campaña no cuentan.
--   3. El permiso no cambia: el coordinador de otra campaña, un colportor y quien no tiene sesión no
--      pueden; el ADMIN sí.
--   4. Lo que el colportor ve: la inscripción y la zona de una campaña por empezar bajan con el sync
--      (mis_inscripciones_no_terminadas()), pero no es una campaña vigente (estado de la cuenta).
begin;
select * from no_plan();

-- --- helpers -------------------------------------------------------------------
create or replace function pg_temp.actuar_como(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('role', 'authenticated', true);
end $$;

create or replace function pg_temp.actuar_como_servidor() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
end $$;

create or replace function pg_temp.actuar_sin_jwt() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
  perform set_config('role', 'authenticated', true);
end $$;

-- El DETAIL de un error (lo que PostgREST devuelve en `details`); throws_ok no lo mira.
create or replace function pg_temp.detalle_error(p_sql text) returns text language plpgsql as $$
declare
  v_detalle text;
begin
  execute p_sql;
  return null;
exception when others then
  get stacked diagnostics v_detalle = pg_exception_detail;
  return v_detalle;
end $$;

-- El uuid de un personaje del test: a1, a2, ad, a0, b1..bb, c1, d1.., e1..
create or replace function pg_temp.u(p_sufijo text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000063' || p_sufijo)::uuid
$$;

-- Hoy en Montevideo (hoy_montevideo() no se ejecuta como authenticated).
create or replace function pg_temp.hoy() returns date language sql stable as $$
  select (now() at time zone 'America/Montevideo')::date
$$;

-- --- fixtures (como postgres, sin RLS) -----------------------------------------
-- Staff: a1 coordina todas las campañas menos e6; a2 coordina e6; ad ADMIN; a0 colportor.
-- Campañas (hoy = día de Montevideo):
--   e1 En curso A         hoy-10 .. hoy+30     e2 Por empezar A      hoy+5 .. hoy+60
--   e3 Por empezar B      hoy+10 .. hoy+90     e4 Terminada          hoy-90 .. hoy-30
--   e5 En curso B         hoy-5 .. (sin fin)   e6 Por empezar de a2  hoy+5 .. hoy+60
--   e7 Termina hoy        hoy-20 .. hoy        e8 Terminó ayer       hoy-20 .. hoy-1
--   e9 Empieza mañana     hoy+1 .. hoy+40      ea Borrada            hoy-10 .. hoy+30
--   eb Empieza hoy        hoy .. hoy+30
-- Colportores (verificados):
--   b1 sin inscripción        b2 en e1 (en curso)         b3 en e2 (por empezar)
--   b4 en e1 (en curso)       b5 en e2 (por empezar)      b6 con baja en e1, sin otra
--   b7 en e4 (terminada)      b8 con baja en e2           b9 en ea (campaña borrada)
--   ba sin inscripción        bb suspendido        bc sin inscripción
--   bd en eb (empieza hoy)   be en e8 (terminó ayer)
--   bf en e1 y en e5 (dos en curso, solo posible por fixture: prueba qué campaña nombra el aviso)
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'antes62-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','a2','ad','a0','b1','b2','b3','b4','b5','b6','b7','b8','b9','ba','bb','bc','bd','be','bf']) s;

insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('ad','ADMIN'), ('a0','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

update public.usuario set suspendido_en = now() where id = pg_temp.u('bb');

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais antes62', 'ZJ');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro) values
  (pg_temp.u('c1'), 'Ciudad antes62', 'Departamento de prueba', pg_temp.u('c0'), -34.9, -56.16);

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, deleted_at) values
  (pg_temp.u('e1'), 'En curso A',        'VERANO',   pg_temp.hoy() - 10, pg_temp.hoy() + 30, pg_temp.u('a1'), null),
  (pg_temp.u('e2'), 'Por empezar A',     'INVIERNO', pg_temp.hoy() + 5,  pg_temp.hoy() + 60, pg_temp.u('a1'), null),
  (pg_temp.u('e3'), 'Por empezar B',     'INVIERNO', pg_temp.hoy() + 10, pg_temp.hoy() + 90, pg_temp.u('a1'), null),
  (pg_temp.u('e4'), 'Terminada',         'VERANO',   pg_temp.hoy() - 90, pg_temp.hoy() - 30, pg_temp.u('a1'), null),
  (pg_temp.u('e5'), 'En curso B',        'VERANO',   pg_temp.hoy() - 5,  null,               pg_temp.u('a1'), null),
  (pg_temp.u('e6'), 'Por empezar de a2', 'INVIERNO', pg_temp.hoy() + 5,  pg_temp.hoy() + 60, pg_temp.u('a2'), null),
  (pg_temp.u('e7'), 'Termina hoy',       'VERANO',   pg_temp.hoy() - 20, pg_temp.hoy(),      pg_temp.u('a1'), null),
  (pg_temp.u('e8'), 'Termino ayer',      'VERANO',   pg_temp.hoy() - 20, pg_temp.hoy() - 1,  pg_temp.u('a1'), null),
  (pg_temp.u('e9'), 'Empieza manana',    'INVIERNO', pg_temp.hoy() + 1,  pg_temp.hoy() + 40, pg_temp.u('a1'), null),
  (pg_temp.u('ea'), 'Borrada',           'VERANO',   pg_temp.hoy() - 10, pg_temp.hoy() + 30, pg_temp.u('a1'), now()),
  (pg_temp.u('eb'), 'Empieza hoy',       'VERANO',   pg_temp.hoy(),      pg_temp.hoy() + 30, pg_temp.u('a1'), null);
insert into public.campania_ciudad (campania_id, ciudad_id)
select c.id, pg_temp.u('c1') from public.campania c
 where c.id in (pg_temp.u('e1'), pg_temp.u('e2'), pg_temp.u('e3'), pg_temp.u('e4'), pg_temp.u('e5'),
                pg_temp.u('e6'), pg_temp.u('e7'), pg_temp.u('e8'), pg_temp.u('e9'), pg_temp.u('ea'),
                pg_temp.u('eb'));

-- Zonas: z2 y z3 en las campañas por empezar e2 y e3; z1 en la en curso e1; z4 en la terminada e4.
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m)
select x.id, x.nombre, cc.id, 'RADIAL', -34.9, -56.16, 300
  from (values (pg_temp.u('f2'), 'Zona por empezar', pg_temp.u('e2')),
               (pg_temp.u('f3'), 'Zona por empezar B', pg_temp.u('e3')),
               (pg_temp.u('f1'), 'Zona en curso', pg_temp.u('e1')),
               (pg_temp.u('f4'), 'Zona terminada', pg_temp.u('e4'))) x(id, nombre, campania_id)
  join public.campania_ciudad cc on cc.campania_id = x.campania_id;

insert into public.campania_colportor (campania_id, usuario_id, deleted_at) values
  (pg_temp.u('e1'), pg_temp.u('b2'), null),
  (pg_temp.u('e2'), pg_temp.u('b3'), null),
  (pg_temp.u('e1'), pg_temp.u('b4'), null),
  (pg_temp.u('e2'), pg_temp.u('b5'), null),
  (pg_temp.u('e1'), pg_temp.u('b6'), now()),
  (pg_temp.u('e4'), pg_temp.u('b7'), null),
  (pg_temp.u('e2'), pg_temp.u('b8'), now()),
  (pg_temp.u('ea'), pg_temp.u('b9'), null),
  (pg_temp.u('eb'), pg_temp.u('bd'), null),
  (pg_temp.u('e8'), pg_temp.u('be'), null),
  (pg_temp.u('e1'), pg_temp.u('bf'), null),
  (pg_temp.u('e5'), pg_temp.u('bf'), null);

-- ---------------------------------------------------------------------------
-- 1. Una campaña por empezar admite inscribir (el caso de Marta y Agustín)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));

select lives_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('e2'), pg_temp.u('b1')),
  'inscribir en una campaña por empezar: se puede (antes CI002)');
select pg_temp.actuar_como_servidor();
select results_eq(
  format($$ select campania_id, usuario_id, zona_id, deleted_at is null from public.campania_colportor
             where campania_id = %L and usuario_id = %L $$, pg_temp.u('e2'), pg_temp.u('b1')),
  format($$ values (%L::uuid, %L::uuid, null::uuid, true) $$, pg_temp.u('e2'), pg_temp.u('b1')),
  'la inscripción quedó viva y sin zona');
select pg_temp.actuar_como(pg_temp.u('a1'));
select throws_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('e2'), pg_temp.u('b1')),
  'CI006', null, 'volver a sumarlo en la misma campaña por empezar: CI006, no una fila nueva');
select pg_temp.actuar_como_servidor();
select is((select count(*) from public.campania_colportor
            where campania_id = pg_temp.u('e2') and usuario_id = pg_temp.u('b1')),
          1::bigint, 'sigue habiendo una sola inscripción');
select pg_temp.actuar_como(pg_temp.u('a1'));

-- Asignar zona antes del inicio.
select is(
  (select zona_id from public.asignar_zona(pg_temp.u('e2'), pg_temp.u('b1'), pg_temp.u('f2'))),
  pg_temp.u('f2'), 'asignar_zona() en una campaña por empezar: se puede (antes CZ002)');
select is(
  (select zona_id from public.asignar_zona(pg_temp.u('e2'), pg_temp.u('b1'), pg_temp.u('f2'))),
  pg_temp.u('f2'), 'asignar la misma zona otra vez: idempotente');
select throws_ok(
  format($$ select public.asignar_zona(%L, %L, %L) $$, pg_temp.u('e2'), pg_temp.u('b1'), pg_temp.u('f3')),
  'CZ006', null, 'la zona de otra campaña por empezar: CZ006');
select throws_ok(
  format($$ select public.asignar_zona(%L, %L, %L) $$, pg_temp.u('e2'), pg_temp.u('ba'), pg_temp.u('f2')),
  'CZ003', null, 'quien no está en la campaña por empezar: CZ003 (la regla que sigue a la campaña)');
select throws_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('e2'), pg_temp.u('bb')),
  'CI005', null, 'una cuenta suspendida tampoco se suma antes del inicio: CI005');

-- Lo que ve el panel de esa campaña.
select results_eq(
  format($$ select usuario_id, zona_id, zona_nombre from public.colportores_de_campania(%L)
             where usuario_id = %L $$, pg_temp.u('e2'), pg_temp.u('b1')),
  format($$ values (%L::uuid, %L::uuid, 'Zona por empezar'::text) $$, pg_temp.u('b1'), pg_temp.u('f2')),
  'colportores_de_campania() de la campaña por empezar lista al inscripto con su zona');
select results_eq(
  format($$ select id, de_esta_campania from public.zonas_asignables(%L) $$, pg_temp.u('e2')),
  format($$ values (%L::uuid, true) $$, pg_temp.u('f2')),
  'zonas_asignables() de la campaña por empezar lista su zona');

-- Quitar la zona también.
select is(
  (select zona_id from public.quitar_zona(pg_temp.u('e2'), pg_temp.u('b1'))),
  null::uuid, 'quitar_zona() en una campaña por empezar: se puede (antes CZ002)');
select is(
  (select zona_id from public.asignar_zona(pg_temp.u('e2'), pg_temp.u('b1'), pg_temp.u('f2'))),
  pg_temp.u('f2'), 'y se vuelve a asignar');

-- La vista 23 («Añadir colportor») busca en una campaña por empezar.
select results_eq(
  format($$ select usuario_id, motivo_bloqueo from public.buscar_candidatos(%L, 'antes62-ba@example.com') $$,
         pg_temp.u('e2')),
  format($$ values (%L::uuid, null::text) $$, pg_temp.u('ba')),
  'buscar_candidatos() en una campaña por empezar contesta (antes CI002) y deja añadir');

-- Una inscripción dada de baja en la campaña por empezar se reactiva, sin zona.
select results_eq(
  format($$ select usuario_id, motivo_bloqueo from public.buscar_candidatos(%L, 'antes62-b8@example.com') $$,
         pg_temp.u('e2')),
  format($$ values (%L::uuid, null::text) $$, pg_temp.u('b8')),
  'quien se quitó de la campaña por empezar aparece sin bloqueo');
select pg_temp.actuar_como_servidor();
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(
  (select (c).usuario_id from (select public.inscribir_colportor(pg_temp.u('e2'), pg_temp.u('b8')) as c) x),
  pg_temp.u('b8'), 'inscribir de nuevo a quien se quitó de la campaña por empezar: la reactiva');
select pg_temp.actuar_como_servidor();
select is((select count(*) from public.campania_colportor
            where campania_id = pg_temp.u('e2') and usuario_id = pg_temp.u('b8')),
          1::bigint, 'la reactivación es la misma fila: sin una nueva');
select pg_temp.actuar_como(pg_temp.u('a1'));

-- ---------------------------------------------------------------------------
-- 2. Los bordes del día: termina hoy sí, terminó ayer no, empieza mañana sí
-- ---------------------------------------------------------------------------
select lives_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('e7'), pg_temp.u('b1')),
  'la campaña que termina hoy admite inscripciones');
select throws_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('e8'), pg_temp.u('ba')),
  'CI002', null, 'la que terminó ayer: CI002');
select lives_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('e9'), pg_temp.u('ba')),
  'la que empieza mañana admite inscripciones');

-- ---------------------------------------------------------------------------
-- 3. Una campaña terminada o borrada se rechaza como siempre
-- ---------------------------------------------------------------------------
select throws_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('e4'), pg_temp.u('ba')),
  'CI002', 'La campaña ya terminó. Elegí una campaña en curso o por empezar.',
  'inscribir en una terminada: CI002 con el aviso que guía');
select throws_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('ea'), pg_temp.u('ba')),
  'CI001', null, 'una borrada: CI001');
select throws_ok(
  format($$ select * from public.buscar_candidatos(%L, 'antes62') $$, pg_temp.u('e4')),
  'CI002', 'La campaña ya terminó. Elegí una campaña en curso o por empezar.',
  'buscar_candidatos() en una terminada: CI002 con el mismo aviso');
select throws_ok(
  format($$ select public.asignar_zona(%L, %L, %L) $$, pg_temp.u('e4'), pg_temp.u('b7'), pg_temp.u('f4')),
  'CZ002', 'La campaña ya terminó: ya no se asignan zonas.', 'asignar_zona() en una terminada: CZ002 con el aviso que guía');
select throws_ok(
  format($$ select public.quitar_zona(%L, %L) $$, pg_temp.u('e4'), pg_temp.u('b7')),
  'CZ002', 'La campaña ya terminó: ya no se asignan zonas.', 'quitar_zona() en una terminada: CZ002');
select throws_ok(
  format($$ select public.asignar_zona(%L, %L, %L) $$, pg_temp.u('ea'), pg_temp.u('b9'), pg_temp.u('f1')),
  'CZ001', null, 'asignar_zona() en una borrada: CZ001');

-- ---------------------------------------------------------------------------
-- 4. R-CM02: una en curso y otra por empezar, sí; dos en el mismo momento, no
-- ---------------------------------------------------------------------------
-- b2 está en e1 (en curso): sumarlo a una por empezar, sí; a otra en curso, no.
select lives_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('e2'), pg_temp.u('b2')),
  'en curso + por empezar: se puede (el colportor sigue en e1 y se suma a e2)');
select throws_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('e5'), pg_temp.u('b4')),
  'CI007', 'Está en campaña En curso A. Reasignar primero.', 'dos en curso a la vez: CI007 con el literal de la HU');
select is(
  pg_temp.detalle_error(format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('e5'), pg_temp.u('b4')))::jsonb,
  jsonb_build_object('campania_id', pg_temp.u('e1'), 'campania_nombre', 'En curso A'),
  'CI007 trae en details la campaña en conflicto (id y nombre)');
select throws_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('e3'), pg_temp.u('b2')),
  'CI007', 'Está en campaña Por empezar A. Reasignar primero.',
  'b2 (en e1 en curso y en e2 por empezar) a otra por empezar: el conflicto es e2, no e1');
-- b3 está en e2 (por empezar): sumarlo a una en curso, sí; a otra por empezar, no.
select lives_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('e1'), pg_temp.u('b3')),
  'por empezar + en curso: se puede (el colportor está en e2 y se suma a e1)');
select throws_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('e3'), pg_temp.u('b5')),
  'CI007', 'Está en campaña Por empezar A. Reasignar primero.', 'dos por empezar a la vez: CI007');
-- Con las tres cosas a la vez, el aviso nombra la que empezó más tarde y es del mismo momento.
select throws_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('e3'), pg_temp.u('b3')),
  'CI007', 'Está en campaña Por empezar A. Reasignar primero.',
  'b3 (en e1 en curso y en e2 por empezar) a otra por empezar: el conflicto es e2, no e1');
select throws_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('e5'), pg_temp.u('b3')),
  'CI007', 'Está en campaña En curso A. Reasignar primero.',
  'b3 a otra en curso: el conflicto es e1, no e2');

-- Lo que no cuenta como «otra campaña».
select lives_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('e5'), pg_temp.u('b6')),
  'una inscripción dada de baja en otra campaña en curso no cuenta');
select lives_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('e1'), pg_temp.u('b7')),
  'una inscripción viva en una campaña terminada no cuenta (en curso)');
select lives_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('e3'), pg_temp.u('b9')),
  'una inscripción en una campaña borrada no cuenta (por empezar)');
select throws_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('e7'), pg_temp.u('b4')),
  'CI007', null, 'la que termina hoy sigue siendo en curso: dos en curso, CI007');

-- Los bordes del día en la campaña «otra»: la que empieza hoy ya está en curso, la que termina hoy
-- todavía, la que empieza mañana sigue por empezar y la que terminó ayer no cuenta.
select throws_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('e5'), pg_temp.u('bd')),
  'CI007', 'Está en campaña Empieza hoy. Reasignar primero.', 'la otra empieza hoy: está en curso, dos en curso, CI007');
select lives_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('e2'), pg_temp.u('bd')),
  'la otra empieza hoy (en curso) y esta empieza en cinco días: se puede');
select throws_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('e5'), pg_temp.u('b1')),
  'CI007', 'Está en campaña Termina hoy. Reasignar primero.', 'la otra termina hoy: sigue en curso, CI007');
select throws_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('e3'), pg_temp.u('ba')),
  'CI007', 'Está en campaña Empieza manana. Reasignar primero.', 'la otra empieza mañana: sigue por empezar, CI007 con otra por empezar');
select lives_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('e5'), pg_temp.u('be')),
  'la otra terminó ayer: ya no cuenta');

select throws_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('e7'), pg_temp.u('bf')),
  'CI007', 'Está en campaña En curso B. Reasignar primero.', 'con dos en conflicto, el aviso nombra la que empezó más tarde');
select throws_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('e1'), pg_temp.u('b6')),
  'CI007', 'Está en campaña En curso B. Reasignar primero.',
  'una campaña en curso sin fecha de fin cuenta: reactivar a b6 en e1 mientras está en e5, CI007');
select lives_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('e5'), pg_temp.u('b9')),
  'una inscripción viva en una campaña borrada y en curso (ea) no cuenta');

-- La vista 23 muestra el mismo bloqueo que el RPC.
select results_eq(
  format($$ select usuario_id, motivo_bloqueo from public.buscar_candidatos(%L, 'antes62-b5@example.com') $$,
         pg_temp.u('e3')),
  format($$ values (%L::uuid, 'EN_OTRA_CAMPANIA'::text) $$, pg_temp.u('b5')),
  'buscar_candidatos() en e3: b5, que ya está en otra por empezar, sale bloqueado');
select results_eq(
  format($$ select usuario_id, motivo_bloqueo from public.buscar_candidatos(%L, 'antes62-b5@example.com') $$,
         pg_temp.u('e5')),
  format($$ values (%L::uuid, null::text) $$, pg_temp.u('b5')),
  'buscar_candidatos() en e5 (en curso): b5, que está en una por empezar, sale sin bloqueo');

-- ---------------------------------------------------------------------------
-- 5. El permiso no cambia
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a2'));
select throws_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('e3'), pg_temp.u('ba')),
  '42501', null, 'el coordinador de otra campaña no inscribe en una por empezar ajena');
select throws_ok(
  format($$ select public.asignar_zona(%L, %L, %L) $$, pg_temp.u('e2'), pg_temp.u('b1'), pg_temp.u('f2')),
  '42501', null, 'ni asigna zona');
select throws_ok(
  format($$ select public.quitar_zona(%L, %L) $$, pg_temp.u('e2'), pg_temp.u('b1')),
  '42501', null, 'ni la quita');
select throws_ok(
  format($$ select * from public.buscar_candidatos(%L, 'antes62') $$, pg_temp.u('e2')),
  '42501', null, 'ni busca candidatos');
select lives_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('e6'), pg_temp.u('b6')),
  'su propia campaña por empezar, sí');

select pg_temp.actuar_como(pg_temp.u('a0'));
select throws_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('e3'), pg_temp.u('ba')),
  '42501', null, 'un colportor no inscribe');
select throws_ok(
  format($$ select public.asignar_zona(%L, %L, %L) $$, pg_temp.u('e2'), pg_temp.u('b1'), pg_temp.u('f2')),
  '42501', null, 'ni asigna zona');

select pg_temp.actuar_sin_jwt();
select throws_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('e3'), pg_temp.u('ba')),
  '42501', null, 'sin sesión no se inscribe');
select throws_ok(
  format($$ select public.asignar_zona(%L, %L, %L) $$, pg_temp.u('e2'), pg_temp.u('b1'), pg_temp.u('f2')),
  '42501', null, 'ni se asigna zona');

select pg_temp.actuar_como(pg_temp.u('ad'));
select lives_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('e3'), pg_temp.u('bc')),
  'el ADMIN inscribe en cualquier campaña por empezar');
select is(
  (select zona_id from public.asignar_zona(pg_temp.u('e3'), pg_temp.u('bc'), pg_temp.u('f3'))),
  pg_temp.u('f3'), 'y asigna zona');

-- ---------------------------------------------------------------------------
-- 6. Lo que ve el colportor
-- ---------------------------------------------------------------------------
-- El sync baja la campaña por empezar y su zona (mis_inscripciones_no_terminadas, 0013); el estado de
-- la cuenta y las zonas de la RLS siguen mirando solo las en curso (pendiente del PR, P2).
-- mis_inscripciones_no_terminadas() es interna (la llaman los DEFINER del pull y la RLS): se llama con la
-- sesión de b1 pero con el rol del servidor.
select pg_temp.actuar_como(pg_temp.u('b1'));
select set_config('role', 'postgres', true);
select is(
  (select zona_id from public.mis_inscripciones_no_terminadas() where campania_id = pg_temp.u('e2')),
  pg_temp.u('f2'), 'el colportor ve su zona de la campaña por empezar (baja el mapa antes del inicio)');
select is(
  (select count(*) from public.mis_campanias_vigentes() where campania_id = pg_temp.u('e2')),
  0::bigint, 'pero la campaña por empezar todavía no es una campaña vigente suya');

select * from finish();
rollback;
