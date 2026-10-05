-- pgTAP · migración 0026 (backend-supabase#56; decisión de Cristian del 02/10 y del orquestador en
-- docs-organizacion#31): «Marcar como duplicado» pasa todo de B a A y da de baja B, en una sola
-- transacción y de forma idempotente.
--   1. dos casas con espacio único: se funde en el de A (personas en las dos, solo en B, dadas de
--      baja) y pasan visitas, agendas, ventas y cobranzas, también las de otro colportor;
--   2. edificios: los espacios pasan a A sin mezclarse; casa sin único en A; tipos distintos;
--   3. errores (UB003, UB004, 42501, 22023, P0002), el servidor, y que nada queda a medias;
--   4. idempotencia, el par cruzado y lo que un teléfono sube tarde;
--   5. las reglas de 0021: gracia (CG001) y sin campaña (42501);
--   6. forma y privilegios.
begin;
select * from no_plan();

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
create or replace function pg_temp.u(p text) returns uuid language sql as $$ select ('01920000-0000-7000-8000-0000000032' || p)::uuid $$;
-- Foto de todo lo que toca la función (id, versión y baja): dos fotos iguales = no se tocó nada.
create or replace function pg_temp.foto() returns text language sql as $$
  select md5(string_agg(x, ',' order by x)) from (
    select 'u' || id::text || sync_version::text || coalesce(deleted_at::text, '') x from public.ubicacion
    union all select 'e' || id::text || ubicacion_id::text || sync_version::text || coalesce(deleted_at::text, '') from public.espacio
    union all select 'p' || id::text || espacio_id::text || sync_version::text || coalesce(deleted_at::text, '') from public.espacio_persona
    union all select 'v' || id::text || espacio_persona_id::text || sync_version::text from public.visita
    union all select 'a' || id::text || espacio_persona_id::text || sync_version::text from public.agenda
    union all select 't' || id::text || espacio_persona_id::text || sync_version::text from public.venta
    union all select 'c' || id::text || venta_id::text || sync_version::text from public.cobranza
    union all select 'h' || ubicacion_id::text || sync_version::text || coalesce(deleted_at::text, '') from public.house_status
  ) f;
$$;
-- La llamada de la vista 10: B (duplicada), A (conservada).
create or replace function pg_temp.dup(p_b text, p_a text) returns jsonb language sql as $$
  select public.marcar_como_duplicado(pg_temp.u(p_b), pg_temp.u(p_a));
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Verano vigente en c1; b1 y b2 inscriptos sin zona; b3 sin campaña.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'dupl-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','b3']) s;
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais dupl', 'ZD');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro)
values (pg_temp.u('c1'), 'Ciudad dupl', pg_temp.u('c0'), -34.9, -56.2);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin)
values (pg_temp.u('e1'), 'Verano dupl', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values (pg_temp.u('f1'), pg_temp.u('e1'), pg_temp.u('c1'));
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  (pg_temp.u('e1'), pg_temp.u('b1'), null),
  (pg_temp.u('e1'), pg_temp.u('b2'), null);

-- Ubicaciones (todas de c1, cada una con su dirección): quién la registró y el tipo.
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by, deleted_at)
select pg_temp.u(x.u), x.tipo, 'Dupl ' || x.u, x.u, -34.9 - x.n * 0.01, -56.2, pg_temp.u('c1'), pg_temp.u(x.quien),
       case when x.u = '0a' then now() end
  from (values ('01', 'CASA', 'b1', 1), ('02', 'CASA', 'b2', 2), ('03', 'CASA', 'b1', 3),
               ('04', 'EDIFICIO', 'b1', 4), ('05', 'EDIFICIO', 'b2', 5),
               ('06', 'CASA', 'b1', 6), ('07', 'CASA', 'b1', 7),
               ('08', 'EDIFICIO', 'b1', 8), ('09', 'CASA', 'b1', 9),
               ('0a', 'CASA', 'b1', 10), ('0b', 'CASA', 'b2', 11),
               ('0c', 'CASA', 'b1', 12), ('0d', 'CASA', 'b1', 13),
               ('0e', 'CASA', 'b2', 14), ('0f', 'CASA', 'b2', 15)) x(u, tipo, quien, n);

-- Espacios. 11: único de A1; 12: único de B1; 13 y 14: deptos 1 y 2 de A2; 15, 16 y 17: deptos 1 y
-- 3 de B2 y uno dado de baja y vacío; 18: único de B3 (A3 no tiene); 19: depto de A8 (edificio);
-- 1a: único de B9 (casa); 1b: de 0b; 1c: de 0f.
insert into public.espacio (id, ubicacion_id, numero_depto, created_by, deleted_at)
select pg_temp.u(x.e), pg_temp.u(x.ub), x.depto, pg_temp.u(x.quien), case when x.e = '17' then now() end
  from (values ('11', '01', null, 'b1'), ('12', '02', null, 'b2'),
               ('13', '04', '1', 'b1'), ('14', '04', '2', 'b1'),
               ('15', '05', '1', 'b2'), ('16', '05', '3', 'b2'), ('17', '05', '9', 'b2'),
               ('18', '07', null, 'b1'), ('19', '08', '1', 'b1'), ('1a', '09', null, 'b1'),
               ('1b', '0b', null, 'b2'), ('1c', '0f', null, 'b2')) x(e, ub, depto, quien);

-- Vínculos con personas. Personas: a1 en A1 y B1; a2 muerta en A1 y viva en B1; a3 solo en B1; a4
-- viva en A1 y muerta en B1.
insert into public.espacio_persona (id, espacio_id, persona_id, created_by, deleted_at, ubicacion_cobranza_alt_id)
select pg_temp.u(x.ep), pg_temp.u(x.e), pg_temp.u(x.p), pg_temp.u(x.quien),
       case when x.muerto then now() end, case when x.ep = '31' then pg_temp.u('03') end
  from (values ('21', '11', 'a1', 'b1', false), ('22', '11', 'a2', 'b1', true), ('23', '11', 'a4', 'b1', false),
               ('31', '12', 'a1', 'b2', false), ('32', '12', 'a2', 'b2', false),
               ('33', '12', 'a3', 'b1', false), ('34', '12', 'a4', 'b2', true),
               ('24', '15', 'a5', 'b2', false), ('25', '18', 'a6', 'b1', false),
               ('26', '1b', 'a7', 'b2', false), ('27', '1c', 'a8', 'b2', false)) x(ep, e, p, quien, muerto);

-- Eventos: de B1, de las dos manos (41 y 51 son de b2; 42 y 53 de b1).
insert into public.visita (id, espacio_persona_id, fecha, tipo_resultado, colportor_id, created_by)
select pg_temp.u(x.v), pg_temp.u(x.ep), now(), 'ENTREVISTA', pg_temp.u(x.quien), pg_temp.u(x.quien)
  from (values ('41', '31', 'b2'), ('42', '33', 'b1'), ('43', '34', 'b2'), ('44', '24', 'b2'),
               ('46', '26', 'b2'), ('47', '27', 'b2')) x(v, ep, quien);
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by)
select pg_temp.u(x.v), pg_temp.u(x.ep), 'T-' || x.v, 100000, now(), pg_temp.u(x.quien), pg_temp.u(x.quien)
  from (values ('51', '31', 'b2'), ('52', '32', 'b2'), ('53', '33', 'b1'), ('54', '24', 'b2'),
               ('55', '25', 'b1'), ('57', '26', 'b2'), ('58', '27', 'b2')) x(v, ep, quien);
insert into public.cobranza (id, venta_id, monto, medio, fecha, created_by)
values (pg_temp.u('61'), pg_temp.u('51'), 50000, 'EFECTIVO', now(), pg_temp.u('b2'));
insert into public.agenda (id, espacio_persona_id, tipo, fecha_programada, colportor_id, created_by)
values (pg_temp.u('71'), pg_temp.u('31'), 'ENTREVISTA', now(), pg_temp.u('b2'), pg_temp.u('b2'));
-- El estado de cada casa: A con una entrevista programada; B con una venta.
insert into public.house_status (ubicacion_id, lat, lon, tipo_ubicacion, color, prioridad) values
  (pg_temp.u('01'), -34.91, -56.2, 'CASA', 'ENTREVISTA_PROGRAMADA', 3),
  (pg_temp.u('02'), -34.92, -56.2, 'CASA', 'VENTA_COMPLETA', 4);

-- ---------------------------------------------------------------------------
-- 1. Dos casas con espacio único
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));

-- La baja común de B está bloqueada por sus ventas: la función no pasa por ahí.
select throws_ok(format('update public.ubicacion set deleted_at = now() where id = %L', pg_temp.u('02')),
                 'UB001', null, 'la baja común de B se bloquea por sus ventas (0018)');

select is(pg_temp.dup('02', '01'),
          jsonb_build_object('duplicada_id', pg_temp.u('02'), 'conservada_id', pg_temp.u('01'), 'ya_unida', false,
                             'espacios_pasados', 0, 'espacios_unidos', 1,
                             'personas', 3, 'visitas', 3, 'ventas', 3, 'cobranzas', 1),
          'b1 marca la 02 (de b2) como duplicado de la 01: se funde el único y la respuesta cuenta lo que pasó');

select pg_temp.actuar_como_servidor();
select isnt((select deleted_at from public.ubicacion where id = pg_temp.u('02')), null, 'B quedó dada de baja');
select is((select deleted_at from public.ubicacion where id = pg_temp.u('01')), null, 'A sigue viva');
select isnt((select deleted_at from public.house_status where ubicacion_id = pg_temp.u('02')), null,
            'el estado de B quedó dado de baja con B');
select is((select color || ':' || (deleted_at is null)::text from public.house_status where ubicacion_id = pg_temp.u('01')),
          'ENTREVISTA_PROGRAMADA:true', 'el estado de A no se toca: lo recalcula la app');
select isnt((select deleted_at from public.espacio where id = pg_temp.u('12')), null, 'el único de B quedó dado de baja (soft delete)');
select is((select count(*) from public.espacio where ubicacion_id = pg_temp.u('01') and deleted_at is null and numero_depto is null),
          1::bigint, 'A sigue con un solo espacio único vivo');
select is((select deleted_at from public.espacio where id = pg_temp.u('11')), null, 'y es el suyo');

-- Personas.
select is((select espacio_id from public.espacio_persona where id = pg_temp.u('33')), pg_temp.u('11'),
          'la persona que solo estaba en B pasó al único de A, con su mismo vínculo');
select is((select deleted_at is null from public.espacio_persona where id = pg_temp.u('33')), true, 'y sigue viva');
select isnt((select deleted_at from public.espacio_persona where id = pg_temp.u('31')), null,
            'el vínculo de B con la persona a1 (también en A) quedó dado de baja');
select is((select deleted_at from public.espacio_persona where id = pg_temp.u('21')), null, 'el de A con a1 sigue vivo');
select is((select deleted_at from public.espacio_persona where id = pg_temp.u('22')), null,
          'el de A con a2, que estaba dado de baja, se reactivó porque en B estaba vivo');
select isnt((select deleted_at from public.espacio_persona where id = pg_temp.u('32')), null, 'y el de B con a2 quedó dado de baja');
select isnt((select deleted_at from public.espacio_persona where id = pg_temp.u('34')), null, 'el de B con a4, que ya estaba dado de baja, sigue así');
select is((select deleted_at from public.espacio_persona where id = pg_temp.u('23')), null, 'y el de A con a4 sigue vivo');
select is((select ubicacion_cobranza_alt_id from public.espacio_persona where id = pg_temp.u('21')), pg_temp.u('03'),
          'A hereda la ubicación de cobranza que tenía el vínculo de B (no se pierde)');
select is((select count(*) from public.espacio_persona where espacio_id = pg_temp.u('11') and deleted_at is null),
          4::bigint, 'el único de A tiene las cuatro personas, una vez cada una');

-- Eventos: todo cuelga de A y nada se perdió.
select is((select espacio_persona_id from public.visita where id = pg_temp.u('41')), pg_temp.u('21'), 'la visita de b2 en a1 pasó al vínculo de A');
select is((select espacio_persona_id from public.venta  where id = pg_temp.u('51')), pg_temp.u('21'), 'la venta de b2 en a1 pasó al vínculo de A');
select is((select espacio_persona_id from public.agenda where id = pg_temp.u('71')), pg_temp.u('21'), 'la agenda también');
select is((select venta_id from public.cobranza where id = pg_temp.u('61')), pg_temp.u('51'), 'la cobranza sigue en su venta');
select is((select espacio_persona_id from public.venta  where id = pg_temp.u('52')), pg_temp.u('22'), 'la venta en a2 pasó al vínculo reactivado de A');
select is((select espacio_persona_id from public.visita where id = pg_temp.u('43')), pg_temp.u('23'), 'la visita en a4 pasó al vínculo vivo de A');
select is((select espacio_persona_id from public.venta  where id = pg_temp.u('53')), pg_temp.u('33'), 'la venta en a3 sigue en su vínculo, que ahora está en A');
select is((select count(*) from public.venta where id in (pg_temp.u('51'), pg_temp.u('52'), pg_temp.u('53')) and deleted_at is null),
          3::bigint, 'ninguna venta se borró');
select is((select colportor_id from public.venta where id = pg_temp.u('51')), pg_temp.u('b2'), 'y siguen siendo de su colportor');
select is((select count(*) from public.venta v join public.espacio_persona ep on ep.id = v.espacio_persona_id
                             join public.espacio e on e.id = ep.espacio_id
            where e.ubicacion_id = pg_temp.u('02')), 0::bigint, 'no cuelga ninguna venta de B');
select is((select count(*) from public.visita v join public.espacio_persona ep on ep.id = v.espacio_persona_id
                             join public.espacio e on e.id = ep.espacio_id
            where e.ubicacion_id = pg_temp.u('02')), 0::bigint, 'ni ninguna visita');

-- ---------------------------------------------------------------------------
-- 2. Idempotencia y par cruzado
-- ---------------------------------------------------------------------------
create temp table foto_1 as select pg_temp.foto() f;
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.dup('02', '01'),
          jsonb_build_object('duplicada_id', pg_temp.u('02'), 'conservada_id', pg_temp.u('01'), 'ya_unida', true,
                             'espacios_pasados', 0, 'espacios_unidos', 0, 'personas', 0, 'visitas', 0, 'ventas', 0, 'cobranzas', 0),
          'reintentar: B ya se había unido a A, responde éxito (ya_unida) sin contar nada');
select pg_temp.actuar_como(pg_temp.u('b2'));
select is((pg_temp.dup('02', '01') ->> 'ya_unida')::boolean, true, 'también si reintenta la otra persona (b2)');
select pg_temp.actuar_como_servidor();
select is(pg_temp.foto(), (select f from foto_1), 'y no se tocó ni una fila (ni siquiera la versión)');

-- El par cruzado: A ya no está viva para conservar a B.
select pg_temp.actuar_como(pg_temp.u('b1'));
select throws_ok(format('select public.marcar_como_duplicado(%L, %L)', pg_temp.u('01'), pg_temp.u('02')),
                 'UB003', 'La ubicación que ibas a conservar ya está dada de baja. Revisá el par de nuevo.',
                 'conservar la 02 (ya de baja) y dar de baja la 01: UB003, con el texto de la HU');
select pg_temp.actuar_como_servidor();
select is(pg_temp.foto(), (select f from foto_1), 'sin tocar nada');

-- Lo que un teléfono sube tarde: una venta al vínculo de B ya fundido y una persona nueva en el
-- único de B. Quedan colgando de B (dada de baja), y volver a llamar lo pasa a A.
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by)
values (pg_temp.u('56'), pg_temp.u('31'), 'T-56', 100000, now(), pg_temp.u('b2'), pg_temp.u('b2'));
insert into public.espacio_persona (id, espacio_id, persona_id, created_by) values (pg_temp.u('28'), pg_temp.u('12'), pg_temp.u('a9'), pg_temp.u('b2'));
insert into public.visita (id, espacio_persona_id, fecha, tipo_resultado, colportor_id, created_by)
values (pg_temp.u('45'), pg_temp.u('28'), now(), 'RECHAZO', pg_temp.u('b2'), pg_temp.u('b2'));
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.dup('02', '01'),
          jsonb_build_object('duplicada_id', pg_temp.u('02'), 'conservada_id', pg_temp.u('01'), 'ya_unida', false,
                             'espacios_pasados', 0, 'espacios_unidos', 1,
                             'personas', 1, 'visitas', 1, 'ventas', 1, 'cobranzas', 0),
          'lo que subió tarde se detecta: la llamada repetida lo pasa a A');
select pg_temp.actuar_como_servidor();
select is((select espacio_persona_id from public.venta where id = pg_temp.u('56')), pg_temp.u('21'), 'la venta tardía pasó al vínculo de A');
select is((select espacio_id from public.espacio_persona where id = pg_temp.u('28')), pg_temp.u('11'), 'la persona tardía, al único de A');
select isnt((select deleted_at from public.ubicacion where id = pg_temp.u('02')), null, 'B sigue dada de baja');
create temp table foto_2 as select pg_temp.foto() f;
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((pg_temp.dup('02', '01') ->> 'ya_unida')::boolean, true, 'y a la tercera ya no queda nada');
select pg_temp.actuar_como_servidor();
select is(pg_temp.foto(), (select f from foto_2), 'sin tocar nada');

-- ---------------------------------------------------------------------------
-- 3. Edificios, casa sin único en A y tipos distintos
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.dup('05', '04'),
          jsonb_build_object('duplicada_id', pg_temp.u('05'), 'conservada_id', pg_temp.u('04'), 'ya_unida', false,
                             'espacios_pasados', 2, 'espacios_unidos', 0,
                             'personas', 1, 'visitas', 1, 'ventas', 1, 'cobranzas', 0),
          'edificios: los espacios de B pasan a A sin mezclarse (el depto 1 de B no se funde con el 1 de A)');
select pg_temp.actuar_como_servidor();
select is((select count(*) from public.espacio where ubicacion_id = pg_temp.u('04') and deleted_at is null), 4::bigint,
          'A queda con sus dos deptos y los dos de B');
select is((select count(*) from public.espacio where ubicacion_id = pg_temp.u('04') and numero_depto = '1'), 2::bigint,
          'dos deptos «1»: cada espacio se agrega sin mezclarse');
select is((select ubicacion_id from public.espacio where id = pg_temp.u('17')), pg_temp.u('05'),
          'el espacio de B dado de baja y vacío se queda en B: no hay nada que mover');
select is((select u.id from public.venta v join public.espacio_persona ep on ep.id = v.espacio_persona_id
                          join public.espacio e on e.id = ep.espacio_id join public.ubicacion u on u.id = e.ubicacion_id
            where v.id = pg_temp.u('54')), pg_temp.u('04'), 'la venta del depto de B cuelga de A');
select isnt((select deleted_at from public.ubicacion where id = pg_temp.u('05')), null, 'y B está dada de baja');

select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.dup('07', '06'),
          jsonb_build_object('duplicada_id', pg_temp.u('07'), 'conservada_id', pg_temp.u('06'), 'ya_unida', false,
                             'espacios_pasados', 1, 'espacios_unidos', 0,
                             'personas', 1, 'visitas', 0, 'ventas', 1, 'cobranzas', 0),
          'A es una casa sin espacio único: el de B pasa a serlo');
select pg_temp.actuar_como_servidor();
select is((select ubicacion_id from public.espacio where id = pg_temp.u('18')), pg_temp.u('06'), 'el único de B está en A');
select is((select deleted_at from public.espacio where id = pg_temp.u('18')), null, 'y sigue vivo');

select pg_temp.actuar_como(pg_temp.u('b1'));
select is((pg_temp.dup('09', '08') ->> 'espacios_pasados')::int, 1,
          'A es un edificio y B una casa: el único de B pasa tal cual, sin fundirse');
select pg_temp.actuar_como_servidor();
select is((select ubicacion_id from public.espacio where id = pg_temp.u('1a')), pg_temp.u('08'), 'y está en el edificio');

-- ---------------------------------------------------------------------------
-- 4. Errores
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select throws_ok(format('select public.marcar_como_duplicado(%L, %L)', pg_temp.u('0c'), pg_temp.u('0c')),
                 'UB004', null, 'una ubicación no es duplicado de sí misma');
select throws_ok(format('select public.marcar_como_duplicado(%L, %L)', null, pg_temp.u('0c')),
                 '22023', null, 'faltan las dos ubicaciones: 22023');

-- A dada de baja: no se aplica nada, y B sigue viva con lo suyo.
select pg_temp.actuar_como_servidor();
create temp table foto_3 as select pg_temp.foto() f;
select pg_temp.actuar_como(pg_temp.u('b1'));
select throws_ok(format('select public.marcar_como_duplicado(%L, %L)', pg_temp.u('0b'), pg_temp.u('0a')),
                 'UB003', 'La ubicación que ibas a conservar ya está dada de baja. Revisá el par de nuevo.',
                 'si A ya está dada de baja: UB003');
select pg_temp.actuar_como_servidor();
select is(pg_temp.foto(), (select f from foto_3), 'y no se tocó nada: B sigue viva con su espacio y su venta');

-- Quien no escribe en las dos, o no existen: 42501 (sin revelar cuál).
select pg_temp.actuar_como(pg_temp.u('b3'));
select throws_ok(format('select public.marcar_como_duplicado(%L, %L)', pg_temp.u('0d'), pg_temp.u('0c')),
                 '42501', null, 'b3, que no está en ninguna campaña, no marca nada');
select pg_temp.actuar_como(pg_temp.u('b1'));
select throws_ok(format('select public.marcar_como_duplicado(%L, %L)', gen_random_uuid(), pg_temp.u('0c')),
                 '42501', null, 'una ubicación que no existe: 42501, como una en la que no escribe');
select throws_ok(format('select public.marcar_como_duplicado(%L, %L)', pg_temp.u('0d'), gen_random_uuid()),
                 '42501', null, 'lo mismo con A');
select pg_temp.actuar_como_servidor();
select is((select deleted_at from public.ubicacion where id = pg_temp.u('0d')), null, 'nada se dio de baja');

-- El servidor (sin usuario): mantenimiento; no se exige escribir, y una que no existe es P0002.
select throws_ok(format('select public.marcar_como_duplicado(%L, %L)', gen_random_uuid(), pg_temp.u('0e')),
                 'P0002', null, 'sin usuario y con una ubicación que no existe: P0002');
select is((pg_temp.dup('0f', '0e') ->> 'ventas')::int, 1, 'el servidor marca el par (0f de b2 en la 0e de b2) sin usuario');
select isnt((select deleted_at from public.ubicacion where id = pg_temp.u('0f')), null, 'y B queda dada de baja');
select is((select count(*) from public.espacio where ubicacion_id = pg_temp.u('0e') and deleted_at is null), 1::bigint,
          'el único de B pasó a A (que no tenía)');

-- ---------------------------------------------------------------------------
-- 5. Las reglas de 0021: gracia, atomicidad y sin campaña
-- ---------------------------------------------------------------------------
-- La campaña terminó hace 5 días: b1 todavía escribe (gracia) pero no corrige lo que cargó otro.
update public.campania set fecha_inicio = public.hoy_montevideo() - 60, fecha_fin = public.hoy_montevideo() - 5
 where id = pg_temp.u('e1');
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by)
select pg_temp.u(x.u), 'CASA', 'Gracia ' || x.u, x.u, -35.0 - x.n * 0.01, -56.2, pg_temp.u('c1'), pg_temp.u(x.quien)
  from (values ('d1', 'b1', 1), ('d2', 'b2', 2), ('d3', 'b1', 3), ('d4', 'b1', 4),
               ('d5', 'b1', 5), ('d6', 'b1', 6), ('d7', 'b1', 7), ('d8', 'b1', 8)) x(u, quien, n);
insert into public.espacio (id, ubicacion_id, numero_depto, created_by, created_at) values
  (pg_temp.u('91'), pg_temp.u('d2'), null, pg_temp.u('b2'), now()),
  (pg_temp.u('92'), pg_temp.u('d4'), '1', pg_temp.u('b1'), now() - interval '1 day'),
  (pg_temp.u('93'), pg_temp.u('d4'), '2', pg_temp.u('b2'), now()),
  (pg_temp.u('94'), pg_temp.u('d6'), null, pg_temp.u('b1'), now()),
  (pg_temp.u('95'), pg_temp.u('d8'), null, pg_temp.u('b1'), now());
insert into public.espacio_persona (id, espacio_id, persona_id, created_by)
values (pg_temp.u('29'), pg_temp.u('94'), pg_temp.u('aa'), pg_temp.u('b1'));
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by)
values (pg_temp.u('59'), pg_temp.u('29'), 'T-59', 100000, now(), pg_temp.u('b1'), pg_temp.u('b1'));

select pg_temp.actuar_como(pg_temp.u('b1'));
select throws_ok(format('select public.marcar_como_duplicado(%L, %L)', pg_temp.u('d2'), pg_temp.u('d1')),
                 'CG001', null, 'en la gracia, B tiene un espacio que cargó otro (b2): CG001, lo ajeno no se corrige (0021)');
select throws_ok(format('select public.marcar_como_duplicado(%L, %L)', pg_temp.u('d4'), pg_temp.u('d3')),
                 'CG001', null, 'con un espacio propio y uno ajeno: CG001 también');
select pg_temp.actuar_como_servidor();
select is((select ubicacion_id from public.espacio where id = pg_temp.u('92')), pg_temp.u('d4'),
          'nada a medias: el espacio propio, que se movía primero, quedó en B');
select is((select ubicacion_id from public.espacio where id = pg_temp.u('93')), pg_temp.u('d4'), 'y el ajeno también');
select is((select count(*) from public.ubicacion where id in (pg_temp.u('d2'), pg_temp.u('d4')) and deleted_at is null), 2::bigint,
          'y las dos B siguen vivas');

-- En la gracia, con todo lo que cargó él, sí: las ventas se pasan.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.dup('d6', 'd5') ->> 'ventas', '1', 'en la gracia, con todo lo que cargó b1, la unión pasa y lleva la venta');
select pg_temp.actuar_como_servidor();
select is((select espacio_id from public.espacio_persona where id = pg_temp.u('29')), pg_temp.u('94'), 'la persona viaja con su espacio');
select is((select ubicacion_id from public.espacio where id = pg_temp.u('94')), pg_temp.u('d5'), 'que ahora es de A (d5, que no tenía único)');
select isnt((select deleted_at from public.ubicacion where id = pg_temp.u('d6')), null, 'y B (d6) quedó de baja');

-- Terminada hace más de 15 días: sin ninguna campaña en la que escribir, ni lo propio.
update public.campania set fecha_inicio = public.hoy_montevideo() - 90, fecha_fin = public.hoy_montevideo() - 30
 where id = pg_temp.u('e1');
select pg_temp.actuar_como(pg_temp.u('b1'));
select throws_ok(format('select public.marcar_como_duplicado(%L, %L)', pg_temp.u('d8'), pg_temp.u('d7')),
                 '42501', null, 'con la campaña terminada hace más de 15 días, ni lo que cargó él: 42501');
select pg_temp.actuar_como_servidor();
select is((select ubicacion_id from public.espacio where id = pg_temp.u('95')), pg_temp.u('d8'), 'y no se movió nada');

-- ---------------------------------------------------------------------------
-- 6. Forma y privilegios
-- ---------------------------------------------------------------------------
select has_function('public', 'marcar_como_duplicado', array['uuid', 'uuid'], 'la función existe');
select ok((select p.prosecdef from pg_proc p where p.oid = 'public.marcar_como_duplicado(uuid, uuid)'::regprocedure),
          'SECURITY DEFINER: mueve lo de otros colportores');
select ok((select p.proconfig::text like '%search_path%' from pg_proc p where p.oid = 'public.marcar_como_duplicado(uuid, uuid)'::regprocedure),
          'con search_path vacío');
select ok(not has_function_privilege('anon', 'public.marcar_como_duplicado(uuid, uuid)', 'execute'), 'anon no la ejecuta');
select ok(has_function_privilege('authenticated', 'public.marcar_como_duplicado(uuid, uuid)', 'execute'), 'authenticated sí');
select ok(has_function_privilege('service_role', 'public.marcar_como_duplicado(uuid, uuid)', 'execute'), 'service_role sí');

select * from finish();
rollback;
