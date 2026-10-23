-- pgTAP · migración 0035 (backend-supabase#69; decisiones de Cristian del 06/10, PR#65 y docs#31):
-- «Marcar como duplicado» guarda la unión, el servidor redirige a A lo que llega después nombrando a
-- B, y una casa que queda con más de un espacio pasa a edificio.
--   1. La unión: el registro (ubicacion_union / espacio_union), las referencias a B reapuntadas a A
--      (cobranza alternativa, agenda, decisiones sobre pares) y la respuesta con el tipo.
--   2. Lo que llega después, por sync.push y por el INSERT/UPDATE directo: ventas, visitas, agendas,
--      vínculos y espacios que nombran a B, a su espacio único fundido o a un vínculo fundido caen en
--      A; nada se rechaza ni se pierde, y la RLS de quien escribe sigue valiendo.
--   3. Cruces: B ya unida (a A o a otra), el sentido contrario, la cadena A → C.
--   4. Unir tipos: casa + edificio → EDIFICIO; casa + casa → CASA; casa + negocio de un espacio → CASA;
--      un negocio que recibe varios sigue NEGOCIO; un edificio sigue EDIFICIO; un depto que llega
--      tarde a una casa ya unida la pasa a edificio.
--   5. ubicacion_par_decidido: reapuntada, reordenada (a < b), el par consigo mismo de baja, y la
--      más reciente cuando el mismo colportor ya decidió el par nuevo.
--   6. Permisos: quién lee y escribe el registro, quién ejecuta qué, y la unión por permiso.
--   «Venta tarde» (0064, #105): el vínculo que llega de una persona que ya tiene uno en el espacio
--   fundido se junta (`merged` en el push, espacio_persona_union), en la sección 2; la cadena de uniones
--   está en 0056.
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
create or replace function pg_temp.actuar_como_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', 'anon', true);
  perform set_config('role', 'anon', true);
end $$;
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000044' || p)::uuid;
$$;
-- «sqlstate», u «ok», de lo que hace una sentencia (la excepción no deja la transacción rota).
create or replace function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;
create or replace function pg_temp.job(p_ent text, p_op text, p_payload jsonb) returns jsonb language sql as $$
  select jsonb_build_object('client_op_id', gen_random_uuid(), 'entity', p_ent, 'op', p_op, 'payload', p_payload);
$$;
create or replace function pg_temp.resultados(p_r jsonb) returns text[] language sql as $$
  select array_agg((e ->> 'outcome') || coalesce(' ' || (e ->> 'code'), '') order by i)
    from jsonb_array_elements(p_r -> 'results') with ordinality x(e, i);
$$;
-- Foto de todo lo que toca la unión (id, versión y baja): dos fotos iguales = no se tocó nada.
create or replace function pg_temp.foto() returns text language sql as $$
  select md5(string_agg(x, ',' order by x)) from (
    select 'u' || id::text || sync_version::text || coalesce(deleted_at::text, '') x from public.ubicacion
    union all select 'e' || id::text || ubicacion_id::text || sync_version::text || coalesce(deleted_at::text, '') from public.espacio
    union all select 'p' || id::text || espacio_id::text || sync_version::text || coalesce(deleted_at::text, '') from public.espacio_persona
    union all select 'v' || id::text || espacio_persona_id::text || sync_version::text from public.visita
    union all select 'a' || id::text || espacio_persona_id::text || sync_version::text from public.agenda
    union all select 't' || id::text || espacio_persona_id::text || sync_version::text from public.venta
    union all select 'd' || id::text || ubicacion_a_id::text || ubicacion_b_id::text || sync_version::text || coalesce(deleted_at::text, '') from public.ubicacion_par_decidido
    union all select 'U' || id::text from public.ubicacion_union
    union all select 'E' || id::text from public.espacio_union
  ) f;
$$;
-- La llamada de la vista 10: B (duplicada), A (conservada).
create or replace function pg_temp.dup(p_b text, p_a text) returns jsonb language sql as $$
  select public.marcar_como_duplicado(pg_temp.u(p_b), pg_temp.u(p_a));
$$;
create or replace function pg_temp.vivos(p_ub text) returns bigint language sql as $$
  select count(*) from public.espacio where ubicacion_id = pg_temp.u(p_ub) and deleted_at is null;
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Ids (prefijo 44): usuarios b1 b2 b3 ad; ubicaciones 01..18; espacios 30..4f; personas 60..6f;
-- vínculos 70..8f; visitas 90..; ventas a0..; agendas c1..; decisiones d0..; lo que sube tarde, e0..
-- Usuarios: b1 y b2 en Verano (c1); b2 también en Otoño (c2); b3 sin campaña; ad es ADMIN.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'union44-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','b3','ad']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u('ad'), r.id from public.rol r where r.codigo = 'ADMIN';
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('f0'), 'Pais union44', 'ZU');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  (pg_temp.u('f1'), 'Ciudad f1 union44', pg_temp.u('f0'), -34.9, -56.2),
  (pg_temp.u('f2'), 'Ciudad f2 union44', pg_temp.u('f0'), -31.4, -57.9);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin) values
  (pg_temp.u('f3'), 'Verano union44', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30),
  (pg_temp.u('f4'), 'Otoño union44',  'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('f5'), pg_temp.u('f3'), pg_temp.u('f1')),
  (pg_temp.u('f6'), pg_temp.u('f4'), pg_temp.u('f2'));
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  (pg_temp.u('f3'), pg_temp.u('b1'), null),
  (pg_temp.u('f3'), pg_temp.u('b2'), null),
  (pg_temp.u('f4'), pg_temp.u('b2'), null);

-- Ubicaciones (cada una con su dirección, a más de 100 m de las otras): id, tipo, quién, ciudad.
--   01 A, 02 B, 03 C: la unión principal (02 → 01); 03 recibe lo que cuelga de la cobranza alternativa.
--   04 X y 05 Y en f1, 06 Z en f2: la cadena (Y → Z, después X → Y).
--   07 casa + 08 edificio · 09/0a casa + casa · 0b casa + 0c negocio · 0d negocio + 0e edificio ·
--   0f edificio + 10 casa · 11..15: las decisiones sobre pares · 16/17: sin permiso.
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by)
select pg_temp.u(x.u), x.tipo, 'Union ' || x.u, x.u, case when x.ciudad = 'f2' then -31.4 else -34.9 - x.n * 0.01 end,
       case when x.ciudad = 'f2' then -57.9 - x.n * 0.01 else -56.2 end, pg_temp.u(x.ciudad), pg_temp.u(x.quien)
  from (values ('01', 'CASA', 'b1', 'f1', 1), ('02', 'CASA', 'b2', 'f1', 2), ('03', 'CASA', 'b1', 'f1', 3),
               ('04', 'CASA', 'b1', 'f1', 4), ('05', 'CASA', 'b2', 'f1', 5), ('06', 'CASA', 'b2', 'f2', 6),
               ('07', 'CASA', 'b1', 'f1', 7), ('08', 'EDIFICIO', 'b1', 'f1', 8),
               ('09', 'CASA', 'b1', 'f1', 9), ('0a', 'CASA', 'b2', 'f1', 10),
               ('0b', 'CASA', 'b1', 'f1', 11), ('0c', 'NEGOCIO', 'b1', 'f1', 12),
               ('0d', 'NEGOCIO', 'b1', 'f1', 13), ('0e', 'EDIFICIO', 'b1', 'f1', 14),
               ('0f', 'EDIFICIO', 'b1', 'f1', 15), ('10', 'CASA', 'b1', 'f1', 16),
               ('11', 'CASA', 'b1', 'f1', 17), ('12', 'CASA', 'b1', 'f1', 18), ('13', 'CASA', 'b1', 'f1', 19),
               ('14', 'CASA', 'b1', 'f1', 20), ('15', 'CASA', 'b1', 'f1', 21),
               ('16', 'CASA', 'b1', 'f1', 22), ('17', 'CASA', 'b1', 'f1', 23),
               ('18', 'CASA', 'b1', 'f1', 24), ('19', 'CASA', 'b1', 'f1', 25), ('1a', 'CASA', 'b2', 'f2', 7)) x(u, tipo, quien, ciudad, n);

-- Espacios. 30 único de A; 31 único de B; 32 único de C; 33 de B, dado de baja y vacío (depto 9);
-- 34/35/36 únicos de X/Y/Z; 37 único de la casa 07 y 38..3b los cuatro deptos del edificio 08;
-- 3c/3d únicos de 09/0a; 3e/3f únicos de la casa 0b y del negocio 0c; 40 único del negocio 0d y 41/42
-- los dos deptos del edificio 0e; 43/44 deptos del edificio 0f y 45 único de la casa 10.
insert into public.espacio (id, ubicacion_id, numero_depto, created_by, deleted_at)
select pg_temp.u(x.e), pg_temp.u(x.ub), x.depto, pg_temp.u(x.quien), case when x.e = '33' then now() end
  from (values ('30', '01', null, 'b1'), ('31', '02', null, 'b2'), ('32', '03', null, 'b1'), ('33', '02', '9', 'b2'),
               ('34', '04', null, 'b1'), ('35', '05', null, 'b2'), ('36', '06', null, 'b2'),
               ('37', '07', null, 'b1'), ('38', '08', '1', 'b1'), ('39', '08', '2', 'b1'),
               ('3a', '08', '3', 'b1'), ('3b', '08', '4', 'b1'),
               ('3c', '09', null, 'b1'), ('3d', '0a', null, 'b2'),
               ('3e', '0b', null, 'b1'), ('3f', '0c', null, 'b1'),
               ('40', '0d', null, 'b1'), ('41', '0e', '1', 'b1'), ('42', '0e', '2', 'b1'),
               ('43', '0f', '1', 'b1'), ('44', '0f', '2', 'b1'), ('45', '10', null, 'b1')) x(e, ub, depto, quien);

-- Vínculos. Personas: 60 en A y en B; 61 solo en B; 62 solo en A; 63 en C; 64 en Y; 65 en X.
insert into public.espacio_persona (id, espacio_id, persona_id, created_by, ubicacion_cobranza_alt_id)
select pg_temp.u(x.ep), pg_temp.u(x.e), pg_temp.u(x.p), pg_temp.u(x.quien),
       case when x.alt is not null then pg_temp.u(x.alt) end
  from (values ('70', '30', '60', 'b1', null), ('71', '31', '60', 'b2', null), ('72', '31', '61', 'b1', null),
               ('73', '30', '62', 'b1', null), ('74', '32', '63', 'b1', '02'),
               ('75', '35', '64', 'b2', null), ('76', '34', '65', 'b1', null)) x(ep, e, p, quien, alt);

-- Eventos. Visita 90 y venta a0 (con la cobranza c8) de b2 en el vínculo de B con la persona 60 (71);
-- venta a1 de b1 en el de la persona 61 (72); la venta a2 de b2 en el vínculo de Y (75); agenda c1 de
-- b1 en el vínculo de A, con la casa alternativa B.
insert into public.visita (id, espacio_persona_id, fecha, tipo_resultado, colportor_id, created_by)
values (pg_temp.u('90'), pg_temp.u('71'), now(), 'ENTREVISTA', pg_temp.u('b2'), pg_temp.u('b2'));
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by)
select pg_temp.u(x.v), pg_temp.u(x.ep), 'T-' || x.v, 100000, now(), pg_temp.u(x.quien), pg_temp.u(x.quien)
  from (values ('a0', '71', 'b2'), ('a1', '72', 'b1'), ('a2', '75', 'b2')) x(v, ep, quien);
insert into public.cobranza (id, venta_id, monto, medio, fecha, created_by)
values (pg_temp.u('c8'), pg_temp.u('a0'), 50000, 'EFECTIVO', now(), pg_temp.u('b2'));
insert into public.agenda (id, espacio_persona_id, tipo, fecha_programada, colportor_id, created_by, ubicacion_alt_id)
values (pg_temp.u('c1'), pg_temp.u('70'), 'ENTREVISTA', now(), pg_temp.u('b1'), pg_temp.u('b1'), pg_temp.u('02'));

-- Decisiones sobre pares (ubicaciones 11 B, 12 X, 13 A, 14 W, 15 V; B < X < A).
-- b1: (B, A) el par mismo · (B, X) · (B, W) y (A, W): las dos del mismo par que queda, la de A más
-- vieja · b2: (B, X).
insert into public.ubicacion_par_decidido (id, ubicacion_a_id, ubicacion_b_id, decision, decidido_en, created_by) values
  (pg_temp.u('d1'), pg_temp.u('11'), pg_temp.u('13'), 'CONSERVAR_AMBOS', '2026-10-04 10:00+00', pg_temp.u('b1')),
  (pg_temp.u('d2'), pg_temp.u('11'), pg_temp.u('12'), 'IGNORAR',         '2026-10-04 11:00+00', pg_temp.u('b1')),
  (pg_temp.u('d3'), pg_temp.u('11'), pg_temp.u('14'), 'CONSERVAR_AMBOS', '2026-10-06 12:00+00', pg_temp.u('b1')),
  (pg_temp.u('d4'), pg_temp.u('13'), pg_temp.u('14'), 'IGNORAR',         '2026-10-05 12:00+00', pg_temp.u('b1')),
  (pg_temp.u('d5'), pg_temp.u('11'), pg_temp.u('12'), 'CONSERVAR_AMBOS', '2026-10-04 13:00+00', pg_temp.u('b2'));
-- b2 tiene dos decisiones sobre cada uno de cuatro pares que, tras unir B (11) a A (13), son el mismo
-- (la de B se reapunta a la de A): «Conservar ambos» (CA) gana sobre «Ignorar» (IG) aunque sea más vieja,
-- y entre dos iguales gana la más reciente. e = la que ya estaba en (A, W) · m = la que se mueve.
--   (14) m: IG 07/10, e: CA 03/10 → gana e (la vieja, CA)     (15) m: CA 03/10, e: IG 07/10 → gana m (la vieja, CA)
--   (18) m: IG 03/10, e: IG 08/10 → gana e (la nueva)          (19) m: CA 09/10, e: CA 02/10 → gana m (la nueva)
insert into public.ubicacion_par_decidido (id, ubicacion_a_id, ubicacion_b_id, decision, decidido_en, created_by) values
  (pg_temp.u('d8'), pg_temp.u('11'), pg_temp.u('14'), 'IGNORAR',         '2026-10-07 10:00+00', pg_temp.u('b2')),
  (pg_temp.u('d9'), pg_temp.u('13'), pg_temp.u('14'), 'CONSERVAR_AMBOS', '2026-10-03 10:00+00', pg_temp.u('b2')),
  (pg_temp.u('da'), pg_temp.u('11'), pg_temp.u('15'), 'CONSERVAR_AMBOS', '2026-10-03 10:00+00', pg_temp.u('b2')),
  (pg_temp.u('db'), pg_temp.u('13'), pg_temp.u('15'), 'IGNORAR',         '2026-10-07 10:00+00', pg_temp.u('b2')),
  (pg_temp.u('dc'), pg_temp.u('11'), pg_temp.u('18'), 'IGNORAR',         '2026-10-03 10:00+00', pg_temp.u('b2')),
  (pg_temp.u('dd'), pg_temp.u('13'), pg_temp.u('18'), 'IGNORAR',         '2026-10-08 10:00+00', pg_temp.u('b2')),
  (pg_temp.u('de'), pg_temp.u('11'), pg_temp.u('19'), 'CONSERVAR_AMBOS', '2026-10-09 10:00+00', pg_temp.u('b2')),
  (pg_temp.u('df'), pg_temp.u('13'), pg_temp.u('19'), 'CONSERVAR_AMBOS', '2026-10-02 10:00+00', pg_temp.u('b2'));

-- ---------------------------------------------------------------------------
-- 1. La unión principal: 02 (B) se une a 01 (A)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.dup('02', '01'),
          jsonb_build_object('duplicada_id', pg_temp.u('02'), 'conservada_id', pg_temp.u('01'), 'destino_id', pg_temp.u('01'),
                             'ya_unida', false, 'espacios_pasados', 0, 'espacios_unidos', 1,
                             'personas', 2, 'visitas', 1, 'ventas', 2, 'cobranzas', 1,
                             'tipo_conservada', 'CASA', 'paso_a_edificio', false),
          'b1 une la 02 (de b2) a la 01: se funde el único; la respuesta trae destino, tipo y si pasó a edificio');

select pg_temp.actuar_como_servidor();
-- El registro de la unión.
select is((select conservada_id from public.ubicacion_union where duplicada_id = pg_temp.u('02')), pg_temp.u('01'),
          'ubicacion_union guarda que la 02 se unió a la 01');
select is((select created_by from public.ubicacion_union where duplicada_id = pg_temp.u('02')), pg_temp.u('b1'),
          'y quién la unió');
select is((select count(*) from public.ubicacion_union), 1::bigint, 'una sola fila de unión');
select results_eq(
  $$ select espacio_id, destino_id from public.espacio_union $$,
  $$ values (pg_temp.u('31'), pg_temp.u('30')) $$,
  'espacio_union guarda que el único de B (31) se fundió en el de A (30), y nada más');
select is((select eu.union_id from public.espacio_union eu where eu.espacio_id = pg_temp.u('31')),
          (select un.id from public.ubicacion_union un where un.duplicada_id = pg_temp.u('02')),
          'colgado de su unión');
-- Lo que ya hacía la 0026 sigue igual.
select isnt((select deleted_at from public.ubicacion where id = pg_temp.u('02')), null, 'B quedó dada de baja');
select is((select deleted_at from public.ubicacion where id = pg_temp.u('01')), null, 'A sigue viva');
select is((select espacio_persona_id from public.visita where id = pg_temp.u('90')), pg_temp.u('70'),
          'la visita en la persona 60 pasó al vínculo de A');
select is((select espacio_persona_id from public.venta where id = pg_temp.u('a0')), pg_temp.u('70'), 'la venta también');
select is((select espacio_id from public.espacio_persona where id = pg_temp.u('72')), pg_temp.u('30'),
          'la persona que solo estaba en B pasó al único de A, con su vínculo');
select is((select espacio_persona_id from public.venta where id = pg_temp.u('a1')), pg_temp.u('72'), 'y su venta sigue en su vínculo');
select is((select ubicacion_id from public.espacio where id = pg_temp.u('33')), pg_temp.u('02'),
          'el espacio de B dado de baja y vacío se queda en B');

-- Las referencias a B se reapuntan a A (de todos los colportores, en la misma operación).
select is((select ubicacion_cobranza_alt_id from public.espacio_persona where id = pg_temp.u('74')), pg_temp.u('01'),
          'la cobranza alternativa que nombraba a B (vínculo 74, de la casa C) pasa a A');
select is((select ubicacion_alt_id from public.agenda where id = pg_temp.u('c1')), pg_temp.u('01'),
          'la casa alternativa de la agenda que nombraba a B pasa a A');
select is((select count(*) from public.espacio_persona where ubicacion_cobranza_alt_id = pg_temp.u('02')), 0::bigint,
          'nada apunta ya a B como cobranza alternativa');
select is((select count(*) from public.agenda where ubicacion_alt_id = pg_temp.u('02')), 0::bigint, 'ni como casa de una agenda');

-- Ni una fila de nada se perdió.
select is((select count(*) from public.venta where id in (pg_temp.u('a0'), pg_temp.u('a1')) and deleted_at is null), 2::bigint,
          'ninguna venta se borró');

-- Idempotencia: reintentar da ya_unida sin tocar nada (ni la versión).
create temp table foto_1 as select pg_temp.foto() f;
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.dup('02', '01'),
          jsonb_build_object('duplicada_id', pg_temp.u('02'), 'conservada_id', pg_temp.u('01'), 'destino_id', pg_temp.u('01'),
                             'ya_unida', true, 'espacios_pasados', 0, 'espacios_unidos', 0,
                             'personas', 0, 'visitas', 0, 'ventas', 0, 'cobranzas', 0,
                             'tipo_conservada', 'CASA', 'paso_a_edificio', false),
          'reintentar: ya_unida, sin contar nada');
select pg_temp.actuar_como_servidor();
select is(pg_temp.foto(), (select f from foto_1), 'y no se tocó ni una fila');

-- ---------------------------------------------------------------------------
-- 2. Lo que llega después, por sync.push y por el INSERT directo
-- ---------------------------------------------------------------------------
-- b2 sube lo que hizo sin conexión: una venta y una visita en el vínculo de B ya fundido (71), un
-- vínculo nuevo en el único fundido de B (31), otro de una persona que ya está en A (62), una visita
-- en ese vínculo, un vínculo en el espacio dado de baja que se quedó en B (33), una agenda con la
-- casa alternativa B y un vínculo con la cobranza alternativa B.
select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table lote_tarde on commit drop as
select sync.push(jsonb_build_array(
  pg_temp.job('venta', 'insert', jsonb_build_object('id', pg_temp.u('e1'), 'espacio_persona_id', pg_temp.u('71'),
              'numero_talonario', 'T-E1', 'monto_total', 50000, 'fecha', now())),
  pg_temp.job('visita', 'insert', jsonb_build_object('id', pg_temp.u('e2'), 'espacio_persona_id', pg_temp.u('71'),
              'fecha', now(), 'tipo_resultado', 'RECHAZO')),
  pg_temp.job('espacio_persona', 'insert', jsonb_build_object('id', pg_temp.u('e3'), 'espacio_id', pg_temp.u('31'),
              'persona_id', pg_temp.u('66'))),
  pg_temp.job('espacio_persona', 'insert', jsonb_build_object('id', pg_temp.u('e4'), 'espacio_id', pg_temp.u('31'),
              'persona_id', pg_temp.u('62'))),
  pg_temp.job('visita', 'insert', jsonb_build_object('id', pg_temp.u('e5'), 'espacio_persona_id', pg_temp.u('e4'),
              'fecha', now(), 'tipo_resultado', 'ENTREVISTA')),
  pg_temp.job('espacio_persona', 'insert', jsonb_build_object('id', pg_temp.u('e6'), 'espacio_id', pg_temp.u('33'),
              'persona_id', pg_temp.u('67'))),
  pg_temp.job('agenda', 'insert', jsonb_build_object('id', pg_temp.u('e7'), 'espacio_persona_id', pg_temp.u('71'),
              'tipo', 'ENTREVISTA', 'fecha_programada', now() + interval '1 day', 'ubicacion_alt_id', pg_temp.u('02'))),
  pg_temp.job('espacio_persona', 'insert', jsonb_build_object('id', pg_temp.u('e8'), 'espacio_id', pg_temp.u('32'),
              'persona_id', pg_temp.u('68'), 'ubicacion_cobranza_alt_id', pg_temp.u('02')))
)) as r;
select is((select pg_temp.resultados(r) from lote_tarde),
          array['accepted', 'accepted', 'accepted', 'merged', 'accepted', 'accepted', 'accepted', 'accepted'],
          'el push de lo que llegó tarde se acepta entero: nada se rechaza (el vínculo de la persona que ya estaba en A se juntó)');
select is((select r -> 'results' -> 3 ->> 'merged_into' from lote_tarde), pg_temp.u('73')::text,
          'el que se juntó dice cuál es el vínculo que quedó: el de A con esa persona (73)');
select is((select (r -> 'results' -> 3) - 'client_op_id' from lote_tarde),
          jsonb_build_object('outcome', 'merged', 'merged_into', pg_temp.u('73')),
          'y la respuesta es solo outcome y merged_into (más el client_op_id)');
select pg_temp.actuar_como_servidor();
select is((select espacio_persona_id from public.venta where id = pg_temp.u('e1')), pg_temp.u('70'),
          'la venta tardía en el vínculo de B ya fundido (71) quedó en el de A (70)');
select is((select colportor_id from public.venta where id = pg_temp.u('e1')), pg_temp.u('b2'), 'y sigue siendo de b2');
select is((select espacio_persona_id from public.visita where id = pg_temp.u('e2')), pg_temp.u('70'), 'la visita tardía, también en el vínculo de A');
select is((select espacio_id from public.espacio_persona where id = pg_temp.u('e3')), pg_temp.u('30'),
          'el vínculo nuevo en el único fundido de B (31) quedó en el único de A (30)');
select is((select deleted_at is null from public.espacio_persona where id = pg_temp.u('e3')), true, 'y está vivo');
select is((select count(*) from public.espacio_persona where id = pg_temp.u('e4')), 0::bigint,
          'el vínculo de una persona que ya estaba en A (62) no se guardó como otra fila: se juntó con el de A');
select is((select destino_id from public.espacio_persona_union where duplicada_id = pg_temp.u('e4')), pg_temp.u('73'),
          'y el registro dice que e4 es el 73');
select is((select espacio_persona_id from public.visita where id = pg_temp.u('e5')), pg_temp.u('73'),
          'y su visita cuelga del vínculo de A con esa persona (73)');
select is((select deleted_at from public.espacio_persona where id = pg_temp.u('73')), null, 'que sigue vivo');
select is((select ubicacion_id from public.espacio where id = pg_temp.u('33')), pg_temp.u('01'),
          'el espacio que se había quedado en B se mudó a A cuando le llegó un vínculo');
select is((select espacio_id from public.espacio_persona where id = pg_temp.u('e6')), pg_temp.u('33'), 'y el vínculo quedó en él');
select is((select espacio_persona_id || '/' || ubicacion_alt_id from public.agenda where id = pg_temp.u('e7')),
          pg_temp.u('70')::text || '/' || pg_temp.u('01')::text, 'la agenda tardía, en el vínculo de A y con A como casa alternativa');
select is((select ubicacion_cobranza_alt_id from public.espacio_persona where id = pg_temp.u('e8')), pg_temp.u('01'),
          'y la cobranza alternativa que nombraba a B, en A');
select is((select count(*) from public.espacio_persona ep join public.espacio e on e.id = ep.espacio_id
            where e.ubicacion_id = pg_temp.u('02') and ep.deleted_at is null), 0::bigint,
          'no queda ningún vínculo vivo colgando de B');
select is((select count(*) from public.venta v join public.espacio_persona ep on ep.id = v.espacio_persona_id
                                  join public.espacio e on e.id = ep.espacio_id
            where e.ubicacion_id = pg_temp.u('02') and ep.deleted_at is null), 0::bigint, 'ni ninguna venta');

-- Por el INSERT y el UPDATE directos (como los de PostgREST), con la RLS de quien escribe.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.err(format($$ insert into public.visita (id, espacio_persona_id, fecha, tipo_resultado)
                              values (%L, %L, now(), 'RECHAZO') $$, pg_temp.u('e9'), pg_temp.u('71'))), 'ok',
          'b1 inserta una visita en el vínculo fundido (71) por la API');
select is(pg_temp.err(format('update public.espacio_persona set ubicacion_cobranza_alt_id = %L where id = %L',
                             pg_temp.u('02'), pg_temp.u('74'))), 'ok',
          'b1 vuelve a poner a B como cobranza alternativa de su vínculo 74 (update directo)');
select is((select ubicacion_cobranza_alt_id from public.espacio_persona where id = pg_temp.u('74')), pg_temp.u('01'),
          'y queda en A');
select pg_temp.actuar_como_servidor();
select is((select espacio_persona_id from public.visita where id = pg_temp.u('e9')), pg_temp.u('70'), 'la visita directa quedó en el vínculo de A');
select is((select sync_version from public.espacio_persona where id = pg_temp.u('74')), 2::bigint,
          'con una versión por escritura (la unión y este update): la redirección no suma otra');

-- La RLS de quien escribe sigue valiendo: b3, sin campaña, no carga un espacio en B (que ahora es A).
select pg_temp.actuar_como(pg_temp.u('b3'));
select is(pg_temp.err(format('insert into public.espacio (id, ubicacion_id) values (%L, %L)', pg_temp.u('ea'), pg_temp.u('02'))),
          '42501', 'b3 (sin campaña) no carga un espacio en B: redirigido a A, el WITH CHECK sigue rechazando');
select pg_temp.actuar_como_servidor();
select is((select count(*) from public.espacio where id = pg_temp.u('ea')), 0::bigint, 'y no quedó nada');

-- «Venta tarde» (0064, #105): otro vínculo de una persona que ya tiene uno (con otro id) en el espacio
-- fundido de B —la 60 tiene el 71, dado de baja, en el 31— antes chocaba con el unique (espacio_id,
-- persona_id): 23505, `invalid`. Ahora se junta con el de A (70): no se guarda otra fila, y las visitas
-- y ventas que lo nombran quedan en el de A.
select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table lote_venta_tarde on commit drop as
select sync.push(jsonb_build_array(
  pg_temp.job('espacio_persona', 'insert', jsonb_build_object('id', pg_temp.u('f8'), 'espacio_id', pg_temp.u('31'),
              'persona_id', pg_temp.u('60'))),
  pg_temp.job('visita', 'insert', jsonb_build_object('id', pg_temp.u('f9'), 'espacio_persona_id', pg_temp.u('f8'),
              'fecha', now(), 'tipo_resultado', 'ENTREVISTA')),
  pg_temp.job('venta', 'insert', jsonb_build_object('id', pg_temp.u('fa'), 'espacio_persona_id', pg_temp.u('f8'),
              'numero_talonario', 'T-FA', 'monto_total', 75000, 'fecha', now()))
)) as r;
select is((select pg_temp.resultados(r) from lote_venta_tarde), array['merged', 'accepted', 'accepted'],
          'otro vínculo de la persona 60 (que ya tiene el 71 en el espacio fundido): se junta, y su visita y su venta se aceptan');
select is((select r -> 'results' -> 0 ->> 'merged_into' from lote_venta_tarde), pg_temp.u('70')::text,
          'la respuesta dice que el vínculo que queda es el de A (70)');
select pg_temp.actuar_como_servidor();
select is((select count(*) from public.espacio_persona where id = pg_temp.u('f8')), 0::bigint, 'no se guardó otra fila');
select is((select espacio_persona_id from public.visita where id = pg_temp.u('f9')), pg_temp.u('70'), 'la visita tardía terminó en el vínculo de A');
select is((select espacio_persona_id from public.venta where id = pg_temp.u('fa')), pg_temp.u('70'), 'y la venta también');
select is((select colportor_id from public.venta where id = pg_temp.u('fa')), pg_temp.u('b2'), 'que sigue siendo de b2');
select is((select deleted_at from public.espacio_persona where id = pg_temp.u('70')), null, 'el vínculo de A sigue vivo');
select is((select deleted_at is not null from public.espacio_persona where id = pg_temp.u('71')), true,
          'y el fundido por la unión (71), dado de baja: el segundo vínculo no lo toca');

-- Reintentar el alta (con otro client_op_id, o el mismo job) vuelve a dar `merged`, sin tocar nada, y no
-- es `duplicate`.
create temp table foto_vt as select pg_temp.foto() f;
select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table lote_reintento on commit drop as
select sync.push(jsonb_build_array(
  pg_temp.job('espacio_persona', 'insert', jsonb_build_object('id', pg_temp.u('f8'), 'espacio_id', pg_temp.u('31'),
              'persona_id', pg_temp.u('60')))
)) as r;
select is((select pg_temp.resultados(r) from lote_reintento), array['merged'], 'reintentar el alta vuelve a dar merged');
select is((select r -> 'results' -> 0 ->> 'merged_into' from lote_reintento), pg_temp.u('70')::text, 'con el mismo destino');
select pg_temp.actuar_como_servidor();
select is(pg_temp.foto(), (select f from foto_vt), 'y no se tocó ni una fila');
select is((select count(*) from public.espacio_persona_union where duplicada_id = pg_temp.u('f8')), 1::bigint,
          'ni se repitió el registro');
select results_eq(
  $$ select aceptados, duplicados, conflictos, invalidos from sync.log where operacion = 'push' order by id desc limit 1 $$,
  $$ values (1, 0, 0, 0) $$,
  'el log del push cuenta el merged entre los aceptados');

-- Un alta de un id que YA existe no es un merge, aunque nombre al espacio fundido y a una persona que
-- ya está en A: es el reintento de un job (o un payload roto) y sigue siendo `duplicate`, sin registrar
-- nada ni tocar al vínculo de A. (e3 existe en A con la persona 66; la 62 está en A con el 73.)
create temp table foto_dup as select pg_temp.foto() f;
select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table lote_id_existente on commit drop as
select sync.push(jsonb_build_array(
  pg_temp.job('espacio_persona', 'insert', jsonb_build_object('id', pg_temp.u('e3'), 'espacio_id', pg_temp.u('31'),
              'persona_id', pg_temp.u('62'))),
  pg_temp.job('espacio_persona', 'insert', jsonb_build_object('id', pg_temp.u('70'), 'espacio_id', pg_temp.u('30'),
              'persona_id', pg_temp.u('60')))
)) as r;
select is((select pg_temp.resultados(r) from lote_id_existente), array['duplicate', 'duplicate'],
          'un alta de un id que ya existe sigue siendo duplicate (no merged)');
select pg_temp.actuar_como_servidor();
select is((select count(*) from public.espacio_persona_union where duplicada_id in (pg_temp.u('e3'), pg_temp.u('70'))), 0::bigint,
          'y no se registra como juntado');
select is(pg_temp.foto(), (select f from foto_dup), 'ni se tocó nada');

-- Una visita que llega después, ya en otro lote, nombrando al id que no se guardó, también cae en A.
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.err(format($$ insert into public.visita (id, espacio_persona_id, fecha, tipo_resultado)
                              values (%L, %L, now(), 'RECHAZO') $$, pg_temp.u('fb'), pg_temp.u('f8'))), 'ok',
          'una visita que llega más tarde nombrando a f8 (que no existe) se guarda por la API');
select pg_temp.actuar_como_servidor();
select is((select espacio_persona_id from public.visita where id = pg_temp.u('fb')), pg_temp.u('70'), 'en el vínculo de A');

-- Por el INSERT directo (PostgREST) también se junta: no inserta y no falla.
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.err(format($$ insert into public.espacio_persona (id, espacio_id, persona_id) values (%L, %L, %L) $$,
                             pg_temp.u('fc'), pg_temp.u('31'), pg_temp.u('60'))), 'ok',
          'el INSERT directo de otro vínculo de la persona 60 ya no choca');
select pg_temp.actuar_como_servidor();
select is((select count(*) from public.espacio_persona where id = pg_temp.u('fc')), 0::bigint, 'pero tampoco se guardó');
select is((select destino_id from public.espacio_persona_union where duplicada_id = pg_temp.u('fc')), pg_temp.u('70'), 'se juntó con el 70');

-- El que llega vivo reactiva al de A si estaba dado de baja, y le deja su cobranza alternativa; el que
-- llega dado de baja no lo reactiva. (Persona 69 en A, dada de baja; 6a en A, viva, sin cobranza; 6b en
-- A, dada de baja.)
insert into public.espacio_persona (id, espacio_id, persona_id, created_by, deleted_at) values
  (pg_temp.u('8a'), pg_temp.u('30'), pg_temp.u('69'), pg_temp.u('b1'), now()),
  (pg_temp.u('8b'), pg_temp.u('30'), pg_temp.u('6a'), pg_temp.u('b1'), null),
  (pg_temp.u('8c'), pg_temp.u('30'), pg_temp.u('6b'), pg_temp.u('b1'), now());
select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table lote_reactiva on commit drop as
select sync.push(jsonb_build_array(
  pg_temp.job('espacio_persona', 'insert', jsonb_build_object('id', pg_temp.u('fd'), 'espacio_id', pg_temp.u('31'), 'persona_id', pg_temp.u('69'))),
  pg_temp.job('espacio_persona', 'insert', jsonb_build_object('id', pg_temp.u('fe'), 'espacio_id', pg_temp.u('31'), 'persona_id', pg_temp.u('6a'),
              'ubicacion_cobranza_alt_id', pg_temp.u('03'))),
  pg_temp.job('espacio_persona', 'insert', jsonb_build_object('id', pg_temp.u('ff'), 'espacio_id', pg_temp.u('31'), 'persona_id', pg_temp.u('6b'),
              'deleted_at', now()))
)) as r;
select is((select pg_temp.resultados(r) from lote_reactiva), array['merged', 'merged', 'merged'], 'tres vínculos más se juntan');
select pg_temp.actuar_como_servidor();
select is((select deleted_at from public.espacio_persona where id = pg_temp.u('8a')), null, 'el de A dado de baja se reactivó con el que llegó vivo');
select is((select ubicacion_cobranza_alt_id from public.espacio_persona where id = pg_temp.u('8b')), pg_temp.u('03'),
          'el de A sin cobranza alternativa heredó la del que llegó');
select isnt((select deleted_at from public.espacio_persona where id = pg_temp.u('8c')), null, 'el que llegó dado de baja no reactiva al de A');

-- Si el de A tiene su propia cobranza alternativa, la del que llega no la pisa (aunque lo reactive).
insert into public.espacio_persona (id, espacio_id, persona_id, created_by, deleted_at, ubicacion_cobranza_alt_id)
values (pg_temp.u('9a'), pg_temp.u('30'), pg_temp.u('6c'), pg_temp.u('b1'), now(), pg_temp.u('04'));
select pg_temp.actuar_como(pg_temp.u('b2'));
select is((select pg_temp.resultados(sync.push(jsonb_build_array(
  pg_temp.job('espacio_persona', 'insert', jsonb_build_object('id', pg_temp.u('9b'), 'espacio_id', pg_temp.u('31'),
              'persona_id', pg_temp.u('6c'), 'ubicacion_cobranza_alt_id', pg_temp.u('03'))))))),
          array['merged'], 'otro vínculo más se junta, con cobranza alternativa propia');
select pg_temp.actuar_como_servidor();
select is((select deleted_at from public.espacio_persona where id = pg_temp.u('9a')), null, 'el de A se reactivó');
select is((select ubicacion_cobranza_alt_id from public.espacio_persona where id = pg_temp.u('9a')), pg_temp.u('04'),
          'y conserva su cobranza alternativa: la del que llegó no la pisa');

-- Un alta del servidor (sin usuario) también se junta, pero el registro queda sin dueño: ningún
-- colportor ve a dónde fue (vinculo_juntado solo habla con quien lo subió o con el servidor).
insert into public.espacio_persona (id, espacio_id, persona_id, created_by)
values (pg_temp.u('9c'), pg_temp.u('31'), pg_temp.u('62'), pg_temp.u('b2'));
select is((select count(*) from public.espacio_persona where id = pg_temp.u('9c')), 0::bigint, 'el alta del servidor tampoco se guarda');
select is((select created_by from public.espacio_persona_union where duplicada_id = pg_temp.u('9c')), null, 'su registro no tiene dueño');
select is(public.vinculo_juntado(pg_temp.u('9c')), pg_temp.u('73'), 'el servidor ve a dónde fue');
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(public.vinculo_juntado(pg_temp.u('9c')), null, 'b2 no: no lo subió él');
select pg_temp.actuar_como_servidor();

-- Mover un vínculo que YA existe al espacio fundido, cuando su persona ya está en A, no se junta (no hay
-- un id nuevo que recordar): como en 0035, queda dado de baja donde llegó y el de A sigue vivo.
insert into public.espacio_persona (id, espacio_id, persona_id, created_by)
values (pg_temp.u('9d'), pg_temp.u('3d'), pg_temp.u('62'), pg_temp.u('b2'));
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.err(format('update public.espacio_persona set espacio_id = %L where id = %L', pg_temp.u('31'), pg_temp.u('9d'))), 'ok',
          'b2 mueve un vínculo suyo al espacio fundido, donde su persona (62) ya está en A');
select pg_temp.actuar_como_servidor();
select isnt((select deleted_at from public.espacio_persona where id = pg_temp.u('9d')), null, 'queda dado de baja donde llegó');
select is((select deleted_at from public.espacio_persona where id = pg_temp.u('73')), null, 'y el de A sigue vivo');
select is((select count(*) from public.espacio_persona_union where duplicada_id = pg_temp.u('9d')), 0::bigint, 'sin registro: el vínculo existe');

-- Una vuelta más: nada de lo anterior cambia la unión.
select is(pg_temp.dup('02', '01') ->> 'ya_unida', 'true', 'la unión sigue siendo ya_unida después de todo lo que llegó');

-- ---------------------------------------------------------------------------
-- 3. Cruces
-- ---------------------------------------------------------------------------
-- B ya unida a A: pedir B → C no hace nada y dice adónde fue.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.dup('02', '03') ->> 'ya_unida', 'true', 'B ya se unió a A: pedir B como duplicada de C es ya_unida');
select is(pg_temp.dup('02', '03') ->> 'destino_id', pg_temp.u('01')::text, 'y el destino es A, adonde se unió');
-- El sentido contrario: A no se puede unir a B, que ya se unió a A.
select is(pg_temp.dup('01', '02') ->> 'ya_unida', 'true', 'el sentido contrario (A duplicada de B): ya_unida, no UB003');
select pg_temp.actuar_como_servidor();
select is((select deleted_at from public.ubicacion where id = pg_temp.u('01')), null, 'y A sigue viva');
select is((select count(*) from public.ubicacion_union), 1::bigint, 'sin filas de unión nuevas');

-- La cadena: Y (05) se une a Z (06); después X (04) se une a Y y va a Z.
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.dup('05', '06') ->> 'ya_unida', 'false', 'b2 une la 05 (Y) a la 06 (Z)');
select pg_temp.actuar_como_servidor();
create temp table foto_c as select pg_temp.foto() f;
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.err(format('select public.marcar_como_duplicado(%L, %L)', pg_temp.u('04'), pg_temp.u('05'))), '42501',
          'b1 no escribe en la 06 (Z, a la que se unió Y): X → Y es 42501, sin revelar nada');
select pg_temp.actuar_como_servidor();
select is(pg_temp.foto(), (select f from foto_c), 'y no se tocó nada');
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.dup('04', '05'),
          jsonb_build_object('duplicada_id', pg_temp.u('04'), 'conservada_id', pg_temp.u('05'), 'destino_id', pg_temp.u('06'),
                             'ya_unida', false, 'espacios_pasados', 0, 'espacios_unidos', 1,
                             'personas', 1, 'visitas', 0, 'ventas', 0, 'cobranzas', 0,
                             'tipo_conservada', 'CASA', 'paso_a_edificio', false),
          'b2 une la 04 (X) a la 05 (Y): como Y ya se unió a Z, X va a Z (destino_id)');
select pg_temp.actuar_como_servidor();
select is((select conservada_id from public.ubicacion_union where duplicada_id = pg_temp.u('04')), pg_temp.u('06'),
          'el registro dice que X se unió a Z, no a Y');
select is(public.ubicacion_vigente(pg_temp.u('04')), pg_temp.u('06'), 'ubicacion_vigente(X) es Z');
select is(public.ubicacion_vigente(pg_temp.u('05')), pg_temp.u('06'), 'ubicacion_vigente(Y) es Z');
select is(public.ubicacion_vigente(pg_temp.u('06')), pg_temp.u('06'), 'ubicacion_vigente(Z) es ella misma');
select is((select espacio_id from public.espacio_persona where id = pg_temp.u('75')), pg_temp.u('36'),
          'la persona de Y quedó en el único de Z (con su vínculo y su venta)');
select is((select espacio_id from public.espacio_persona where id = pg_temp.u('76')), pg_temp.u('36'),
          'y la de X, también (en el único de Z)');
select is((select espacio_persona_id from public.venta where id = pg_temp.u('a2')), pg_temp.u('75'), 'la venta de Y sigue en su vínculo');
-- Sentido contrario en la cadena: Z duplicada de X (que ya se unió a Z) y de Y.
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.dup('06', '04') ->> 'ya_unida', 'true', 'Z como duplicada de X, que se unió a Z: ya_unida');
select is(pg_temp.dup('06', '05') ->> 'ya_unida', 'true', 'y de Y, que se unió a Z: ya_unida');
select is(pg_temp.dup('05', '04') ->> 'ya_unida', 'true', 'Y ya se unió (a Z): ya_unida');
-- Lo que llega después nombrando a Y o X (o a sus únicos fundidos) cae en Z, por la cadena.
select is(pg_temp.err(format($$ insert into public.espacio_persona (id, espacio_id, persona_id) values (%L, %L, %L) $$,
                             pg_temp.u('eb'), pg_temp.u('35'), pg_temp.u('69'))), 'ok', 'b2 sube un vínculo en el único fundido de Y');
select is(pg_temp.err(format($$ insert into public.espacio_persona (id, espacio_id, persona_id) values (%L, %L, %L) $$,
                             pg_temp.u('ec'), pg_temp.u('34'), pg_temp.u('6a'))), 'ok', 'y otro en el único fundido de X');
select is(pg_temp.err(format($$ insert into public.visita (id, espacio_persona_id, fecha, tipo_resultado) values (%L, %L, now(), 'RECHAZO') $$,
                             pg_temp.u('ed'), pg_temp.u('76'))), 'ok', 'y una visita en el vínculo de X (76)');
select pg_temp.actuar_como_servidor();
select is((select espacio_id from public.espacio_persona where id = pg_temp.u('eb')), pg_temp.u('36'), 'el de Y cayó en el único de Z');
select is((select espacio_id from public.espacio_persona where id = pg_temp.u('ec')), pg_temp.u('36'), 'el de X también');
select is((select espacio_persona_id from public.visita where id = pg_temp.u('ed')), pg_temp.u('76'), 'la visita en el vínculo de X sigue en él (ya está en Z)');
select is((select count(*) from public.espacio_union eu join public.espacio e on e.id = eu.destino_id
            where e.ubicacion_id = pg_temp.u('06')), 2::bigint, 'dos únicos fundidos en el de Z (los de Y y de X)');

-- La excepción acotada de las políticas de espacio (decisión del 16/10): un depto que sube tarde
-- nombrando a una ubicación unida (Y, o X, que van a Z) se guarda en la que recibió aunque quien lo
-- sube no escriba ahí (b1 no está en la campaña de Z, que es de otra ciudad), siempre que pudiera
-- escribir donde lo nombró. Lo que nombra a Z directamente sigue exigiendo poder escribir en Z.
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table lote_depto_ajeno on commit drop as
select sync.push(jsonb_build_array(
  pg_temp.job('espacio', 'insert', jsonb_build_object('id', pg_temp.u('f7'), 'ubicacion_id', pg_temp.u('05'), 'numero_depto', '7')),
  pg_temp.job('espacio_persona', 'insert', jsonb_build_object('id', pg_temp.u('f9'), 'espacio_id', pg_temp.u('f7'), 'persona_id', pg_temp.u('6b'))),
  pg_temp.job('espacio', 'insert', jsonb_build_object('id', pg_temp.u('fa'), 'ubicacion_id', pg_temp.u('06'), 'numero_depto', '8'))
)) as r;
select is((select pg_temp.resultados(r) from lote_depto_ajeno), array['accepted', 'accepted', 'invalid 42501'],
          'b1 sube un depto nombrando a Y (unida a Z, donde no escribe) y su vínculo: se aceptan; otro depto nombrando a Z directamente: 42501 aun en el mismo lote');
select pg_temp.actuar_como_servidor();
select is((select ubicacion_id from public.espacio where id = pg_temp.u('f7')), pg_temp.u('06'), 'el depto quedó en Z, no se perdió');
select is((select espacio_id from public.espacio_persona where id = pg_temp.u('f9')), pg_temp.u('f7'), 'y su vínculo, en él');
select is((select count(*) from public.espacio where id = pg_temp.u('fa')), 0::bigint, 'el que nombraba a Z directamente no se guardó');
select is((select tipo from public.ubicacion where id = pg_temp.u('06')), 'EDIFICIO', 'Z, una casa con el único fundido, pasó a EDIFICIO con el depto nuevo');
-- Por el UPDATE: un depto propio que b1 mueve a Y (unida a Z) cae en Z; moverlo a Z directamente, no.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.err(format($$ insert into public.espacio (id, ubicacion_id, numero_depto) values (%L, %L, '9') $$,
                             pg_temp.u('fb'), pg_temp.u('03'))), 'ok', 'b1 carga un depto en su casa 03');
select is(pg_temp.err(format('update public.espacio set ubicacion_id = %L where id = %L', pg_temp.u('05'), pg_temp.u('fb'))), 'ok',
          'y lo manda a Y (unida a Z): el UPDATE también entra por la excepción');
select pg_temp.actuar_como_servidor();
select is((select ubicacion_id from public.espacio where id = pg_temp.u('fb')), pg_temp.u('06'), 'quedó en Z');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.err(format($$ insert into public.espacio (id, ubicacion_id, numero_depto) values (%L, %L, '8') $$,
                             pg_temp.u('fc'), pg_temp.u('06'))), '42501', 'b1 no carga un depto en Z nombrándola: 42501, como antes de la 0035');
select pg_temp.actuar_como_servidor();
select pg_temp.actuar_como(pg_temp.u('b3'));
select is(pg_temp.err(format($$ insert into public.espacio (id, ubicacion_id, numero_depto) values (%L, %L, '7') $$,
                             pg_temp.u('fd'), pg_temp.u('05'))), '42501',
          'b3 (sin campaña, no la cargó) no podía escribir en Y: nombrarla unida a Z no le abre nada, 42501');
select pg_temp.actuar_como_servidor();
select is((select count(*) from public.espacio where id in (pg_temp.u('fc'), pg_temp.u('fd'))), 0::bigint, 'y no se guardó ninguno');
-- La marca no sirve para mover el mismo depto a otro lado: la política la compara con el destino.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.err(format('update public.espacio set ubicacion_id = %L where id = %L', pg_temp.u('1a'), pg_temp.u('fb'))), '42501',
          'b1 manda el depto fb (que cayó en Z por la excepción) a la 1a, otra casa de f2 donde no escribe: 42501');
select pg_temp.actuar_como_servidor();
select is((select ubicacion_id from public.espacio where id = pg_temp.u('fb')), pg_temp.u('06'), 'y sigue en Z');
select is((select count(*)::int from pg_policies where schemaname = 'public' and tablename = 'espacio'
            and policyname in ('espacio_por_ubicacion_insert', 'espacio_por_ubicacion_update')
            and (coalesce(with_check, '') like '%colportores.union_espacio%')), 2,
          'las dos políticas de escritura de espacio llevan la rama de la marca, y solo esas');

-- ---------------------------------------------------------------------------
-- 4. Unir tipos
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
-- Casa + edificio con cuatro deptos: A (casa con único) pasa a EDIFICIO con cinco espacios.
select is(pg_temp.dup('08', '07'),
          jsonb_build_object('duplicada_id', pg_temp.u('08'), 'conservada_id', pg_temp.u('07'), 'destino_id', pg_temp.u('07'),
                             'ya_unida', false, 'espacios_pasados', 4, 'espacios_unidos', 0,
                             'personas', 0, 'visitas', 0, 'ventas', 0, 'cobranzas', 0,
                             'tipo_conservada', 'EDIFICIO', 'paso_a_edificio', true),
          'casa + edificio de cuatro deptos: la respuesta dice que pasó a EDIFICIO');
select pg_temp.actuar_como_servidor();
select is((select tipo from public.ubicacion where id = pg_temp.u('07')), 'EDIFICIO', 'A quedó EDIFICIO');
select is(pg_temp.vivos('07'), 5::bigint, 'con cinco espacios: su único y los cuatro deptos');
select is((select sync_version from public.ubicacion where id = pg_temp.u('07')) > 0, true, 'el cambio de tipo subió la versión: el pull lo trae');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.dup('08', '07') ->> 'paso_a_edificio', 'false', 'repetir la unión no vuelve a cambiar el tipo (ya_unida)');
-- Casa + casa: se funde el único y sigue CASA con un espacio.
select is(pg_temp.dup('0a', '09'),
          jsonb_build_object('duplicada_id', pg_temp.u('0a'), 'conservada_id', pg_temp.u('09'), 'destino_id', pg_temp.u('09'),
                             'ya_unida', false, 'espacios_pasados', 0, 'espacios_unidos', 1,
                             'personas', 0, 'visitas', 0, 'ventas', 0, 'cobranzas', 0,
                             'tipo_conservada', 'CASA', 'paso_a_edificio', false),
          'casa + casa: se funde y sigue CASA');
select pg_temp.actuar_como_servidor();
select is((select tipo from public.ubicacion where id = pg_temp.u('09')), 'CASA', 'A sigue CASA');
select is(pg_temp.vivos('09'), 1::bigint, 'con un solo espacio');
-- Casa + negocio de un espacio: se funde y sigue CASA.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.dup('0c', '0b') ->> 'tipo_conservada', 'CASA', 'casa + negocio de un espacio: sigue CASA');
select pg_temp.actuar_como_servidor();
select is(pg_temp.vivos('0b'), 1::bigint, 'con un solo espacio (el del negocio se fundió)');
-- Un negocio que recibe varios sigue NEGOCIO (S17 no cambia: no se toca el tipo).
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.dup('0e', '0d'),
          jsonb_build_object('duplicada_id', pg_temp.u('0e'), 'conservada_id', pg_temp.u('0d'), 'destino_id', pg_temp.u('0d'),
                             'ya_unida', false, 'espacios_pasados', 2, 'espacios_unidos', 0,
                             'personas', 0, 'visitas', 0, 'ventas', 0, 'cobranzas', 0,
                             'tipo_conservada', 'NEGOCIO', 'paso_a_edificio', false),
          'negocio + edificio de dos deptos: el negocio sigue NEGOCIO');
select pg_temp.actuar_como_servidor();
select is(pg_temp.vivos('0d'), 3::bigint, 'con tres espacios');
-- Un edificio que recibe una casa sigue EDIFICIO.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.dup('10', '0f') ->> 'paso_a_edificio', 'false', 'un edificio que recibe una casa: no cambia de tipo');
select pg_temp.actuar_como_servidor();
select is((select tipo from public.ubicacion where id = pg_temp.u('0f')), 'EDIFICIO', 'y sigue EDIFICIO');
select is(pg_temp.vivos('0f'), 3::bigint, 'con sus dos deptos y el único de la casa');

-- Un depto que sube tarde a una casa ya unida (09 se unió a la 0a, que ahora es A = 09) la pasa a edificio.
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table lote_depto on commit drop as
select sync.push(jsonb_build_array(
  pg_temp.job('espacio', 'insert', jsonb_build_object('id', pg_temp.u('ee'), 'ubicacion_id', pg_temp.u('0a'), 'numero_depto', '5'))
)) as r;
select is((select pg_temp.resultados(r) from lote_depto), array['accepted'], 'un depto que sube tarde nombrando a la 0a (unida a la 09) se acepta');
select pg_temp.actuar_como_servidor();
select is((select ubicacion_id from public.espacio where id = pg_temp.u('ee')), pg_temp.u('09'), 'queda en la 09');
select is((select tipo from public.ubicacion where id = pg_temp.u('09')), 'EDIFICIO', 'que pasa a EDIFICIO: ya tiene dos espacios vivos');
-- Un espacio dado de baja que sube tarde no cambia el tipo.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.err(format($$ insert into public.espacio (id, ubicacion_id, numero_depto, deleted_at) values (%L, %L, '6', now()) $$,
                             pg_temp.u('ef'), pg_temp.u('0c'))), 'ok', 'un espacio ya dado de baja que sube tarde nombrando a la 0c (unida a la 0b)');
select pg_temp.actuar_como_servidor();
select is((select tipo from public.ubicacion where id = pg_temp.u('0b')), 'CASA', 'no pasa la casa a edificio: no cuenta como espacio vivo');
select is((select ubicacion_id from public.espacio where id = pg_temp.u('ef')), pg_temp.u('0b'), 'pero igual quedó en A');

-- ---------------------------------------------------------------------------
-- 5. Decisiones sobre pares (ubicacion_par_decidido): «Conservar ambos» gana sobre «Ignorar»; entre dos
--    iguales, la más reciente (decisión del 16/10)
-- ---------------------------------------------------------------------------
-- Antes de la unión, para la cuenta.
select is((select count(*) from public.ubicacion_par_decidido where deleted_at is null), 13::bigint, 'trece decisiones vivas antes de la unión');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.dup('11', '13') ->> 'ya_unida', 'false', 'b1 une la 11 (B) a la 13 (A)');
select pg_temp.actuar_como_servidor();
select is((select deleted_at is not null from public.ubicacion_par_decidido where id = pg_temp.u('d1')), true,
          'la decisión sobre el par (B, A) mismo quedó dada de baja: ya no tiene sentido');
select results_eq(
  $$ select ubicacion_a_id, ubicacion_b_id from public.ubicacion_par_decidido where id = pg_temp.u('d1') $$,
  $$ values (pg_temp.u('11'), pg_temp.u('13')) $$,
  'pero con sus dos ids tal cual (el check a < b no admite (A, A)) y sin perder la decisión');
select results_eq(
  $$ select ubicacion_a_id, ubicacion_b_id, decision, deleted_at is null from public.ubicacion_par_decidido where id = pg_temp.u('d2') $$,
  $$ values (pg_temp.u('12'), pg_temp.u('13'), 'IGNORAR', true) $$,
  'la decisión (B, X) pasó a (X, A): se reordenó para que a < b, y sigue viva');
select results_eq(
  $$ select ubicacion_a_id, ubicacion_b_id, decision, deleted_at is null from public.ubicacion_par_decidido where id = pg_temp.u('d5') $$,
  $$ values (pg_temp.u('12'), pg_temp.u('13'), 'CONSERVAR_AMBOS', true) $$,
  'la de b2 sobre el mismo par también (otro dueño, otra fila)');
select results_eq(
  $$ select id, decision from public.ubicacion_par_decidido
      where created_by = pg_temp.u('b1') and ubicacion_a_id = pg_temp.u('13') and ubicacion_b_id = pg_temp.u('14') and deleted_at is null $$,
  $$ values (pg_temp.u('d3'), 'CONSERVAR_AMBOS') $$,
  'b1 tenía (B, W) y (A, W): queda viva una sola sobre (A, W), CONSERVAR_AMBOS (que además es la más reciente)');
select is((select deleted_at is not null from public.ubicacion_par_decidido where id = pg_temp.u('d4')), true, 'y la otra, la más vieja, se dio de baja');
select is((select count(*) from public.ubicacion_par_decidido where ubicacion_a_id = pg_temp.u('11') or ubicacion_b_id = pg_temp.u('11')), 1::bigint,
          'solo queda el par mismo (B, A) nombrando a B');
-- «Conservar ambos» gana sobre «Ignorar» aunque sea más vieja; entre iguales, la más reciente.
select results_eq(
  $$ select id, decision from public.ubicacion_par_decidido
      where created_by = pg_temp.u('b2') and ubicacion_a_id = pg_temp.u('13') and ubicacion_b_id = pg_temp.u('14') and deleted_at is null $$,
  $$ values (pg_temp.u('d9'), 'CONSERVAR_AMBOS') $$,
  'b2, par (A, W): la que se mueve es IGNORAR más nueva y la que estaba, CONSERVAR_AMBOS más vieja: queda CONSERVAR_AMBOS');
select is((select deleted_at is not null from public.ubicacion_par_decidido where id = pg_temp.u('d8')), true, 'y la IGNORAR se dio de baja, no se borró');
select results_eq(
  $$ select id, decision from public.ubicacion_par_decidido
      where created_by = pg_temp.u('b2') and ubicacion_a_id = pg_temp.u('13') and ubicacion_b_id = pg_temp.u('15') and deleted_at is null $$,
  $$ values (pg_temp.u('da'), 'CONSERVAR_AMBOS') $$,
  'b2, par (A, V): la que se mueve es CONSERVAR_AMBOS más vieja y la que estaba, IGNORAR más nueva: queda la que se mueve');
select is((select deleted_at is not null from public.ubicacion_par_decidido where id = pg_temp.u('db')), true, 'y la IGNORAR que ya estaba se dio de baja');
select results_eq(
  $$ select id from public.ubicacion_par_decidido
      where created_by = pg_temp.u('b2') and ubicacion_a_id = pg_temp.u('13') and ubicacion_b_id = pg_temp.u('18') and deleted_at is null $$,
  $$ values (pg_temp.u('dd')) $$,
  'b2, dos IGNORAR: gana la más reciente, que era la que ya estaba');
select results_eq(
  $$ select id from public.ubicacion_par_decidido
      where created_by = pg_temp.u('b2') and ubicacion_a_id = pg_temp.u('13') and ubicacion_b_id = pg_temp.u('19') and deleted_at is null $$,
  $$ values (pg_temp.u('de')) $$,
  'b2, dos CONSERVAR_AMBOS: gana la más reciente, que era la que se mueve');
select is((select count(*) from public.ubicacion_par_decidido where created_by = pg_temp.u('b2') and deleted_at is null
            and ubicacion_a_id = pg_temp.u('13')), 4::bigint, 'b2 queda con una sola decisión viva por cada uno de los cuatro pares');
-- Una decisión que llega después nombrando a B.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.err(format($$ insert into public.ubicacion_par_decidido (id, ubicacion_a_id, ubicacion_b_id, decision, decidido_en)
                              values (%L, %L, %L, 'IGNORAR', now()) $$, pg_temp.u('d6'), pg_temp.u('11'), pg_temp.u('15'))), 'ok',
          'b1 sube tarde una decisión sobre (B, V)');
select is(pg_temp.err(format($$ insert into public.ubicacion_par_decidido (id, ubicacion_a_id, ubicacion_b_id, decision, decidido_en)
                              values (%L, %L, %L, 'CONSERVAR_AMBOS', now()) $$, pg_temp.u('d7'), pg_temp.u('11'), pg_temp.u('13'))), 'ok',
          'y otra sobre el par mismo (B, A)');
select is(pg_temp.err(format($$ insert into public.ubicacion_par_decidido (id, ubicacion_a_id, ubicacion_b_id, decision, decidido_en)
                              values (%L, %L, %L, 'IGNORAR', now()) $$, pg_temp.u('c2'), pg_temp.u('11'), pg_temp.u('14'))), 'ok',
          'y una IGNORAR sobre (B, W), más nueva que la CONSERVAR_AMBOS de b1 que ya está en (A, W)');
select is(pg_temp.err(format($$ insert into public.ubicacion_par_decidido (id, ubicacion_a_id, ubicacion_b_id, decision, decidido_en)
                              values (%L, %L, %L, 'CONSERVAR_AMBOS', now()) $$, pg_temp.u('c3'), pg_temp.u('11'), pg_temp.u('12'))), 'ok',
          'y una CONSERVAR_AMBOS sobre (B, X), más nueva que la IGNORAR de b1 que ya está en (X, A)');
select pg_temp.actuar_como_servidor();
select is((select deleted_at is not null from public.ubicacion_par_decidido where id = pg_temp.u('c2')), true,
          'la IGNORAR tardía se guardó dada de baja: la CONSERVAR_AMBOS de b1 sigue');
select is((select deleted_at is null from public.ubicacion_par_decidido where id = pg_temp.u('d3')), true, 'viva');
select results_eq(
  $$ select id, decision from public.ubicacion_par_decidido
      where created_by = pg_temp.u('b1') and ubicacion_a_id = pg_temp.u('12') and ubicacion_b_id = pg_temp.u('13') and deleted_at is null $$,
  $$ values (pg_temp.u('c3'), 'CONSERVAR_AMBOS') $$,
  'la CONSERVAR_AMBOS tardía pisó a la IGNORAR que estaba en (X, A)');
select is((select deleted_at is not null from public.ubicacion_par_decidido where id = pg_temp.u('d2')), true, 'que quedó dada de baja');
select results_eq(
  $$ select ubicacion_a_id, ubicacion_b_id, deleted_at is null from public.ubicacion_par_decidido where id = pg_temp.u('d6') $$,
  $$ values (pg_temp.u('13'), pg_temp.u('15'), true) $$,
  'la tardía (B, V) quedó como (A, V), viva');
select results_eq(
  $$ select ubicacion_a_id, ubicacion_b_id, deleted_at is not null from public.ubicacion_par_decidido where id = pg_temp.u('d7') $$,
  $$ values (pg_temp.u('11'), pg_temp.u('13'), true) $$,
  'la tardía sobre el par mismo se guardó dada de baja, con sus ids');

-- ---------------------------------------------------------------------------
-- 6. Permisos
-- ---------------------------------------------------------------------------
-- Las tablas del registro: solo el ADMIN las lee; nadie las escribe.
select pg_temp.actuar_como(pg_temp.u('ad'));
select is((select count(*) from public.ubicacion_union), 9::bigint, 'el ADMIN lee ubicacion_union (las nueve uniones)');
select is((select count(*) from public.espacio_union), 5::bigint, 'y espacio_union (los cinco únicos fundidos)');
select is(pg_temp.err(format('insert into public.ubicacion_union (duplicada_id, conservada_id) values (%L, %L)', pg_temp.u('16'), pg_temp.u('17'))),
          '42501', 'pero ni el ADMIN escribe ubicacion_union por la API');
select is(pg_temp.err(format('delete from public.ubicacion_union where duplicada_id = %L', pg_temp.u('02'))), '42501', 'ni la borra');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select count(*) from public.ubicacion_union), 0::bigint, 'un colportor no ve ubicacion_union (la RLS esconde todo)');
select is((select count(*) from public.espacio_union), 0::bigint, 'ni espacio_union');
select is(pg_temp.err(format('insert into public.ubicacion_union (duplicada_id, conservada_id) values (%L, %L)', pg_temp.u('16'), pg_temp.u('17'))),
          '42501', 'ni la escribe');
select is(pg_temp.err(format('update public.ubicacion_union set conservada_id = %L where duplicada_id = %L', pg_temp.u('17'), pg_temp.u('02'))),
          '42501', 'ni la modifica');
select is(pg_temp.err(format('insert into public.espacio_union (union_id, espacio_id, destino_id) values (%L, %L, %L)',
                             (select id from public.ubicacion_union limit 1), pg_temp.u('30'), pg_temp.u('31'))), '42501',
          'ni espacio_union');
select is(pg_temp.err(format('delete from public.espacio_union where espacio_id = %L', pg_temp.u('31'))), '42501', 'ni la borra');
select pg_temp.actuar_como_anon();
select is(pg_temp.err('select count(*) from public.ubicacion_union'), '42501', 'anon: permission denied al leer ubicacion_union');
select is(pg_temp.err('select count(*) from public.espacio_union'), '42501', 'y espacio_union');
select pg_temp.actuar_como_servidor();
-- Las funciones nuevas: nadie las ejecuta desde la API; la RPC sigue como estaba.
select ok(not has_function_privilege('authenticated', f, 'execute'), 'authenticated NO ejecuta ' || f)
  from unnest(array['public.ubicacion_vigente(uuid)', 'public.redirigir_ubicacion(uuid)', 'public.redirigir_espacio(uuid)',
                    'public.redirigir_vinculo(uuid)',
                    'public.union_respuesta(uuid, uuid, uuid, boolean, integer, integer, integer, integer, integer, integer, boolean)',
                    'public.tg_espacio_union_redirige()', 'public.tg_espacio_persona_union_redirige()',
                    'public.tg_vinculo_union_redirige()', 'public.tg_agenda_union_redirige()',
                    'public.tg_par_decidido_union_redirige()']) f;
select ok(not has_function_privilege('anon', f, 'execute'), 'anon NO ejecuta ' || f)
  from unnest(array['public.ubicacion_vigente(uuid)', 'public.redirigir_ubicacion(uuid)', 'public.redirigir_espacio(uuid)',
                    'public.redirigir_vinculo(uuid)', 'public.tg_espacio_union_redirige()']) f;
select is((select count(*)::int from pg_proc p
            where (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE'))
              and p.pronamespace = 'public'::regnamespace
              and p.proname in ('ubicacion_vigente', 'redirigir_ubicacion', 'redirigir_espacio', 'redirigir_vinculo', 'union_respuesta',
                                'tg_espacio_union_redirige', 'tg_espacio_persona_union_redirige', 'tg_vinculo_union_redirige',
                                'tg_agenda_union_redirige', 'tg_par_decidido_union_redirige')), 0,
          'ninguna de las funciones nuevas tiene EXECUTE para PUBLIC');
select ok(has_function_privilege('authenticated', 'public.marcar_como_duplicado(uuid, uuid)', 'execute'), 'authenticated sigue ejecutando marcar_como_duplicado');
select ok(has_function_privilege('service_role', 'public.marcar_como_duplicado(uuid, uuid)', 'execute'), 'service_role también');
select ok(not has_function_privilege('anon', 'public.marcar_como_duplicado(uuid, uuid)', 'execute'), 'anon no');
select is((select count(*)::int from pg_proc p where p.pronamespace = 'public'::regnamespace
            and p.proname in ('ubicacion_vigente', 'redirigir_ubicacion', 'redirigir_espacio', 'redirigir_vinculo', 'union_respuesta',
                              'tg_espacio_union_redirige', 'tg_espacio_persona_union_redirige', 'tg_vinculo_union_redirige',
                              'tg_agenda_union_redirige', 'tg_par_decidido_union_redirige', 'marcar_como_duplicado')
            and p.prosecdef and p.proconfig = array['search_path=""']), 11,
          'las once son SECURITY DEFINER con search_path vacío');
-- Los triggers existen, uno por tabla, y corren antes que los de auditoría y los de corrección.
select ok(exists (select 1 from pg_trigger t where t.tgrelid = r.t::regclass and t.tgname = r.n and not t.tgisinternal),
          'trigger ' || r.n || ' en ' || r.t)
  from (values ('public.espacio', 'espacio_0_union_redirige'), ('public.espacio_persona', 'espacio_persona_0_union_redirige'),
               ('public.visita', 'visita_0_union_redirige'), ('public.venta', 'venta_0_union_redirige'),
               ('public.agenda', 'agenda_0_union_redirige'), ('public.ubicacion_par_decidido', 'ubicacion_par_decidido_0_union_redirige')) r(t, n);
select is((select t.tgname::text from pg_trigger t where t.tgrelid = r.t::regclass and not t.tgisinternal
                 and (t.tgtype & 2) = 2 and (t.tgtype & 1) = 1
                 order by t.tgname collate "C" limit 1), r.n,
          'el primer trigger BEFORE de ' || r.t || ' (orden de disparo) es el de la unión')
  from (values ('public.espacio', 'espacio_0_union_redirige'), ('public.espacio_persona', 'espacio_persona_0_union_redirige'),
               ('public.visita', 'visita_0_union_redirige'), ('public.venta', 'venta_0_union_redirige'),
               ('public.agenda', 'agenda_0_union_redirige'), ('public.ubicacion_par_decidido', 'ubicacion_par_decidido_0_union_redirige')) r(t, n);
-- Quién une: b3 (sin campaña) y quien no existe: 42501; el servidor sí.
select pg_temp.actuar_como(pg_temp.u('b3'));
select is(pg_temp.err(format('select public.marcar_como_duplicado(%L, %L)', pg_temp.u('17'), pg_temp.u('16'))), '42501',
          'b3, sin campaña, no une un par');
select pg_temp.actuar_como_servidor();
select is((select count(*) from public.ubicacion_union where duplicada_id = pg_temp.u('17')), 0::bigint, 'y no quedó registrada');
select is(pg_temp.dup('17', '16') ->> 'ya_unida', 'false', 'el servidor une el par (service_role, sin usuario)');
select is((select created_by from public.ubicacion_union where duplicada_id = pg_temp.u('17')), null, 'con created_by vacío: lo unió el servidor');
select is(pg_temp.err('select public.ubicacion_vigente(null)'), 'ok', 'ubicacion_vigente(null) no falla (null)');
select is(public.redirigir_ubicacion(null), null, 'redirigir_ubicacion(null) devuelve null');

-- Forma de las tablas nuevas.
select has_table('public', 'ubicacion_union', 'ubicacion_union existe');
select has_table('public', 'espacio_union', 'espacio_union existe');
select is((select count(*)::int from sync.entidad where tabla in ('public.ubicacion_union'::regclass, 'public.espacio_union'::regclass)), 0,
          'ninguna de las dos está en sync.entidad (no van al pull ni al push)');
select is((select count(*)::int from sync.entidad), 23, 'sync.entidad sigue con sus 23 entidades');

-- El registro de los vínculos que se juntaron (0064): solo ids, solo en la nube, lo lee el ADMIN y lo
-- escribe únicamente el trigger; vinculo_juntado() solo cuenta a dónde fue a quien lo subió.
select has_table('public', 'espacio_persona_union', 'espacio_persona_union existe');
select is((select count(*)::int from sync.entidad where tabla = 'public.espacio_persona_union'::regclass), 0,
          'espacio_persona_union no está en sync.entidad (no va al pull ni al push)');
select pg_temp.actuar_como(pg_temp.u('ad'));
select ok((select count(*) from public.espacio_persona_union) >= 5, 'el ADMIN lee espacio_persona_union');
select is(pg_temp.err(format('insert into public.espacio_persona_union (duplicada_id, destino_id) values (%L, %L)',
                             pg_temp.u('f0'), pg_temp.u('70'))), '42501', 'pero ni el ADMIN la escribe por la API');
select is(pg_temp.err(format('delete from public.espacio_persona_union where duplicada_id = %L', pg_temp.u('e4'))), '42501', 'ni la borra');
select is(public.vinculo_juntado(pg_temp.u('e4')), null, 'el ADMIN no subió el e4: vinculo_juntado no le dice a dónde fue');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select count(*) from public.espacio_persona_union), 0::bigint, 'un colportor no ve espacio_persona_union (la RLS esconde todo)');
select is(public.vinculo_juntado(pg_temp.u('e4')), null, 'b1 tampoco subió el e4');
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(public.vinculo_juntado(pg_temp.u('e4')), pg_temp.u('73'), 'b2, que lo subió, sí: el 73');
select is(public.vinculo_juntado(pg_temp.u('f8')), pg_temp.u('70'), 'y el f8: el 70');
select is(public.vinculo_juntado(pg_temp.u('70')), null, 'un id que no se juntó (el 70 existe): null');
select is(public.vinculo_juntado(null), null, 'null: null');
select is(pg_temp.err(format('insert into public.espacio_persona_union (duplicada_id, destino_id) values (%L, %L)',
                             pg_temp.u('f0'), pg_temp.u('70'))), '42501', 'b2 no escribe espacio_persona_union por la API');
select pg_temp.actuar_como_anon();
select is(pg_temp.err('select count(*) from public.espacio_persona_union'), '42501', 'anon: permission denied al leer espacio_persona_union');
select is(pg_temp.err(format('select public.vinculo_juntado(%L)', pg_temp.u('e4'))), '42501', 'y no ejecuta vinculo_juntado');
select pg_temp.actuar_como_servidor();
select is(public.vinculo_juntado(pg_temp.u('e4')), pg_temp.u('73'), 'el servidor (sin usuario) ve a dónde fue cualquiera');
select is((select created_by from public.espacio_persona_union where duplicada_id = pg_temp.u('e4')), pg_temp.u('b2'),
          'el registro guarda quién subió el vínculo');
select is((select count(*) from public.espacio_persona_union where destino_id = duplicada_id), 0::bigint, 'ninguno apunta a sí mismo');

-- ---------------------------------------------------------------------------
-- 7. La marca no abre los espacios ajenos de A (revisión de #85: la excepción de la 3b)
-- ---------------------------------------------------------------------------
-- El trigger deja la marca para cualquier fila que nombre a una B unida donde quien escribe puede
-- escribir, sea suya o no. Si el UPDATE no pedía además `created_by = auth.uid()`, quien escribe en B
-- corregía o daba de baja cualquier espacio de A que ve con solo poner ubicacion_id = B en el SET.
--   · b4 (colportor): Verano en curso en f1 (escribe en Y, unida a Z) y una campaña por empezar en f2
--     (ve Z sin poder escribir en ella).
--   · b5 (coordinador sin campaña): registró la 20 (f1), unida a Z; ve todo y solo puede cargar en ella.
--   · b8 y b9: deptos de b2 en Z, ajenos para los dos.
select pg_temp.actuar_como_servidor();
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'union44-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b4', 'b5']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u('b5'), r.id from public.rol r where r.codigo = 'COORDINADOR';
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin) values
  (pg_temp.u('b6'), 'Pronto union44', 'VERANO', public.hoy_montevideo() + 10, public.hoy_montevideo() + 40);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values (pg_temp.u('b7'), pg_temp.u('b6'), pg_temp.u('f2'));
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  (pg_temp.u('f3'), pg_temp.u('b4'), null),
  (pg_temp.u('b6'), pg_temp.u('b4'), null);
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by)
values (pg_temp.u('20'), 'CASA', 'Union 20', '20', -35.16, -56.2, pg_temp.u('f1'), pg_temp.u('b5'));
insert into public.espacio (id, ubicacion_id, numero_depto, created_by) values
  (pg_temp.u('b8'), pg_temp.u('06'), 'v1', pg_temp.u('b2')),
  (pg_temp.u('b9'), pg_temp.u('06'), 'v2', pg_temp.u('b2'));
select is(pg_temp.dup('20', '06') ->> 'ya_unida', 'false', 'se une la 20 (de b5) a Z, como las otras de Y y X');
select is(public.ubicacion_vigente(pg_temp.u('20')), pg_temp.u('06'), 'y su vigente es Z');

-- Casos 1 y 2: el colportor que escribe en Y (unida a Z) y solo ve Z. Sin la marca, 42501.
select pg_temp.actuar_como(pg_temp.u('b4'));
select is((select count(*) from public.espacio where id in (pg_temp.u('b8'), pg_temp.u('b9'))), 2::bigint,
          'b4 ve los dos deptos de Z (su campaña por empezar en f2)');
select is(pg_temp.err(format($$ update public.espacio set descripcion = 'tocado' where id = %L $$, pg_temp.u('b8'))), '42501',
          'pero no corrige el depto de Z: no escribe ahí, 42501');
select is(pg_temp.err(format($$ update public.espacio set ubicacion_id = %L, descripcion = 'tocado por b4' where id = %L $$,
                             pg_temp.u('05'), pg_temp.u('b8'))), '42501',
          '1. b4 pone ubicacion_id = Y (unida a Z, donde sí escribe) para corregir el depto ajeno b8 de Z: 42501');
select is(pg_temp.err(format($$ update public.espacio set ubicacion_id = %L, deleted_at = now() where id = %L $$,
                             pg_temp.u('05'), pg_temp.u('b9'))), '42501',
          '2. y para darlo de baja (b9): 42501');
-- Caso 3: lo mismo por sync.push.
create temp table lote_ajeno_b4 on commit drop as
select sync.push(jsonb_build_array(
  jsonb_build_object('client_op_id', gen_random_uuid(), 'entity', 'espacio', 'op', 'update',
                     'sync_version', (select sync_version from public.espacio where id = pg_temp.u('b8')),
                     'payload', jsonb_build_object('id', pg_temp.u('b8'), 'ubicacion_id', pg_temp.u('05'), 'descripcion', 'tocado por el push')))) as r;
select is((select pg_temp.resultados(r) from lote_ajeno_b4), array['invalid 42501'],
          '3. el update de b8 con ubicacion_id = Y por sync.push vuelve invalid 42501, no accepted');

-- Caso 4: el coordinador que solo carga en la 20 (unida a Z). Un insert que choca por id (on conflict
-- do nothing: duplicate) dejaba la marca del depto ajeno, y el update de después pasaba.
select pg_temp.actuar_como(pg_temp.u('b5'));
select is((select count(*) from public.espacio where id in (pg_temp.u('b8'), pg_temp.u('b9'))), 2::bigint, 'b5 (coordinador) ve los deptos de Z');
select is(pg_temp.err(format($$ update public.espacio set descripcion = 'tocado' where id = %L $$, pg_temp.u('b8'))), '42501',
          'pero no escribe en ellos (no tiene campaña): 42501');
create temp table lote_marca_ajena on commit drop as
select sync.push(jsonb_build_array(
  pg_temp.job('espacio', 'insert', jsonb_build_object('id', pg_temp.u('b8'), 'ubicacion_id', pg_temp.u('20'), 'numero_depto', 'v1')),
  jsonb_build_object('client_op_id', gen_random_uuid(), 'entity', 'espacio', 'op', 'update',
                     'sync_version', (select sync_version from public.espacio where id = pg_temp.u('b8')),
                     'payload', jsonb_build_object('id', pg_temp.u('b8'), 'ubicacion_id', pg_temp.u('20'), 'descripcion', 'tocado por b5')))) as r;
select is((select pg_temp.resultados(r) from lote_marca_ajena), array['duplicate', 'invalid 42501'],
          '4. un insert que choca con el id de b8 nombrando a la 20, seguido de su update, en un mismo push: duplicate e invalid 42501');

-- Nada se movió, cambió ni se dio de baja.
select pg_temp.actuar_como_servidor();
select results_eq(
  $$ select ubicacion_id, descripcion, deleted_at is null, sync_version, created_by from public.espacio
      where id in (pg_temp.u('b8'), pg_temp.u('b9')) order by id $$,
  $$ values (pg_temp.u('06'), null::text, true, 0::bigint, pg_temp.u('b2')),
            (pg_temp.u('06'), null::text, true, 0::bigint, pg_temp.u('b2')) $$,
  'los dos deptos de Z siguen en Z, sin descripción, vivos, sin versión nueva y de b2');

-- Lo propio sigue entrando: la corrección tardía de un depto que cargó quien lo corrige.
select pg_temp.actuar_como(pg_temp.u('b4'));
select is(pg_temp.err(format($$ insert into public.espacio (id, ubicacion_id, numero_depto) values (%L, %L, 'v3') $$,
                             pg_temp.u('ba'), pg_temp.u('05'))), 'ok', 'b4 sube un depto propio nombrando a Y: entra (cae en Z)');
select is(pg_temp.err(format($$ update public.espacio set ubicacion_id = %L, descripcion = 'corregido' where id = %L $$,
                             pg_temp.u('05'), pg_temp.u('ba'))), 'ok',
          'y lo corrige nombrando a Y otra vez (la corrección tardía de lo propio, por la API)');
create temp table lote_propio_b4 on commit drop as
select sync.push(jsonb_build_array(
  jsonb_build_object('client_op_id', gen_random_uuid(), 'entity', 'espacio', 'op', 'update',
                     'sync_version', (select sync_version from public.espacio where id = pg_temp.u('ba')),
                     'payload', jsonb_build_object('id', pg_temp.u('ba'), 'ubicacion_id', pg_temp.u('05'), 'piso', '3')))) as r;
select is((select pg_temp.resultados(r) from lote_propio_b4), array['accepted'], 'y por sync.push también');
select pg_temp.actuar_como(pg_temp.u('b5'));
select is(pg_temp.err(format($$ insert into public.espacio (id, ubicacion_id, numero_depto) values (%L, %L, 'v4') $$,
                             pg_temp.u('bb'), pg_temp.u('20'))), 'ok', 'b5 carga un depto propio nombrando a la 20, unida a Z: entra');
select pg_temp.actuar_como_servidor();
select results_eq(
  $$ select ubicacion_id, descripcion, piso from public.espacio where id = pg_temp.u('ba') $$,
  $$ values (pg_temp.u('06'), 'corregido'::text, '3'::text) $$,
  'el depto de b4 quedó en Z, corregido');
select is((select ubicacion_id from public.espacio where id = pg_temp.u('bb')), pg_temp.u('06'), 'y el de b5, en Z');

select * from finish();
rollback;
