-- pgTAP · migración 0132 (backend-supabase#202): becas y alquiler con las respuestas del 27/10.
--   A. «Beca perman.»: en una campaña permanente no hay becas (BC006), por la RPC y por el UPDATE directo.
--   B. «Carrera corr»: corregir la carrera recalcula la meta de las inscripciones vivas con beca de campañas que no
--      terminaron, queda en el historial, la lectura de Becas devuelve la marca y lo que no cambia no se toca.
--   C. «Alq. de baja»: quien se da de baja debe 0 y lo pagado queda a favor; al reactivar vuelve a deber.
--   D. «Deuda alq.»: cuenta_alquiler se mantiene en la misma transacción que cada movimiento y coincide con
--      cuentas_de_campania() después de cada uno; quién la lee; privilegios; la vista previa de validar.
-- Va en una transacción.
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

-- Ids (sufijo de dos caracteres HEX).
create or replace function pg_temp.u(p text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000132' || p)::uuid
$$;

-- 'ok' o el SQLSTATE; 'ok' o 'SQLSTATE: mensaje'.
create or replace function pg_temp.cod(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate || ': ' || sqlerrm;
end $$;

-- La beca de una inscripción: tipo|libros|monto. SECURITY DEFINER: se lee sin RLS.
create or replace function pg_temp.beca(p_camp text, p_us text) returns text language sql security definer as $$
  select format('%s|%s|%s', coalesce(cc.tipo_beca, '-'), coalesce(cc.meta_libros::text, '-'),
                coalesce(cc.meta_monto_ces::text, '-'))
    from public.campania_colportor cc
   where cc.campania_id = pg_temp.u(p_camp) and cc.usuario_id = pg_temp.u(p_us)
$$;
create or replace function pg_temp.ver_ins(p_camp text, p_us text) returns bigint language sql security definer as $$
  select cc.sync_version from public.campania_colportor cc
   where cc.campania_id = pg_temp.u(p_camp) and cc.usuario_id = pg_temp.u(p_us)
$$;
-- Eventos de auditoría de un tipo sobre la inscripción de un colportor en una campaña.
create or replace function pg_temp.n_ev(p_evento text, p_camp text, p_us text) returns integer
language sql security definer as $$
  select count(*)::int from auditoria.audit_log a
    join public.campania_colportor cc on cc.id = a.fila_id
   where a.event_type = p_evento and cc.campania_id = pg_temp.u(p_camp) and cc.usuario_id = pg_temp.u(p_us)
$$;
create or replace function pg_temp.meta_ev(p_camp text, p_us text) returns jsonb language sql security definer as $$
  select a.metadata from auditoria.audit_log a
    join public.campania_colportor cc on cc.id = a.fila_id
   where a.event_type = 'meta_de_beca_recalculada' and cc.campania_id = pg_temp.u(p_camp)
     and cc.usuario_id = pg_temp.u(p_us)
   order by a.created_at, a.id limit 1
$$;
create or replace function pg_temp.carrera_de(p_us text) returns text language sql security definer as $$
  select coalesce(right(u.carrera_id::text, 2), '-') from public.usuario u where u.id = pg_temp.u(p_us)
$$;
-- ¿La lectura de Becas marca esta inscripción como recalculada?
create or replace function pg_temp.marca(p_camp text, p_us text) returns text language sql as $$
  select coalesce((select (r.meta_recalculada_en is not null)::text
                     from public.becas_de_campania(pg_temp.u(p_camp)) r where r.usuario_id = pg_temp.u(p_us)), 'sin fila')
$$;
create or replace function pg_temp.asig(p_camp text, p_us text[], p_tipo text) returns text language sql as $$
  select string_agg(format('%s:%s:%s:%s:%s', right(r.usuario_id::text, 2), coalesce(r.tipo_beca, '-'),
                           coalesce(r.meta_libros::text, '-'), coalesce(r.meta_monto_ces::text, '-'),
                           case when r.cambio then 'S' else 'N' end), ';' order by r.usuario_id)
    from public.asignar_beca(pg_temp.u(p_camp), (select array_agg(pg_temp.u(x)) from unnest(p_us) x), p_tipo) r
$$;

-- La fila guardada del alquiler: monto|pagado|por_validar|debe|a_favor (null = n). SECURITY DEFINER: sin RLS.
create or replace function pg_temp.fila(p_us text, p_camp text) returns text language sql security definer as $$
  select coalesce((select format('%s|%s|%s|%s|%s', coalesce(ca.alquiler_monto::text, 'n'), ca.alquiler_pagado,
                                 ca.alquiler_por_validar, coalesce(ca.alquiler_debe::text, 'n'), ca.alquiler_trasladado)
                     from public.cuenta_alquiler ca
                    where ca.usuario_id = pg_temp.u(p_us) and ca.campania_id = pg_temp.u(p_camp)), 'sin fila')
$$;
create or replace function pg_temp.ver(p_us text, p_camp text) returns bigint language sql security definer as $$
  select ca.sync_version from public.cuenta_alquiler ca
   where ca.usuario_id = pg_temp.u(p_us) and ca.campania_id = pg_temp.u(p_camp)
$$;
-- La tabla contra cuentas_de_campania(): «filas|distintas». Lo lee el ADMIN (ve todo) y vuelve al servidor.
create or replace function pg_temp.coincide(p_camp text) returns text language plpgsql as $$
declare
  v text;
begin
  perform pg_temp.actuar_como(pg_temp.u('ad'));
  select format('%s|%s',
           (select count(*) from public.cuentas_de_campania(pg_temp.u(p_camp))),
           (select count(*)
              from public.cuentas_de_campania(pg_temp.u(p_camp)) r
              full join (select * from public.cuenta_alquiler where campania_id = pg_temp.u(p_camp)) ca
                     on ca.usuario_id = r.colportor_id
             where r.colportor_id is null or ca.id is null
                or (r.alquiler_monto, r.alquiler_pagado, r.alquiler_por_validar, r.alquiler_debe,
                    r.alquiler_trasladado, r.alquiler_ultimo_pago_fecha)
                   is distinct from
                   (ca.alquiler_monto, ca.alquiler_pagado, ca.alquiler_por_validar, ca.alquiler_debe,
                    ca.alquiler_trasladado, ca.alquiler_ultimo_pago_fecha)))
    into v;
  perform pg_temp.actuar_como_servidor();
  return v;
end $$;

-- Cuántos eventos de recálculo tienen ese actor (null = sin sesión); y versiones de las inscripciones (plpgsql:
-- la tabla temporal se crea después).
create or replace function pg_temp.n_actor(p_camp text, p_us text, p_actor uuid) returns integer
language sql security definer as $$
  select count(*)::int from auditoria.audit_log a join public.campania_colportor cc on cc.id = a.fila_id
   where a.event_type = 'meta_de_beca_recalculada' and cc.campania_id = pg_temp.u(p_camp)
     and cc.usuario_id = pg_temp.u(p_us) and a.actor_user_id is not distinct from p_actor
$$;
create or replace function pg_temp.versiones_distintas() returns integer language plpgsql security definer as $$
declare n integer;
begin
  select count(*)::int into n from public.campania_colportor cc join antes_b a using (usuario_id, campania_id)
   where cc.sync_version <> a.sync_version
     and not (cc.usuario_id = pg_temp.u('b1') and cc.campania_id in (pg_temp.u('e1'), pg_temp.u('e2')));
  return n;
end $$;
create or replace function pg_temp.version_igual(p_camp text, p_us text) returns boolean language plpgsql security definer as $$
declare v boolean;
begin
  select cc.sync_version = a.sync_version into v from public.campania_colportor cc join antes_b a using (usuario_id, campania_id)
   where cc.campania_id = pg_temp.u(p_camp) and cc.usuario_id = pg_temp.u(p_us);
  return v;
end $$;

create or replace function pg_temp.push1(p_op uuid, p_entidad text, p_tipo text, p_payload jsonb)
returns jsonb language sql as $$
  select sync.push(jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
           'client_op_id', p_op, 'entity', p_entidad, 'op', p_tipo, 'payload', p_payload)))) -> 'results' -> 0;
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Staff: a1 coordina e1, e3, e5, e6 y ea; a2 coordina e2 y eb; ad ADMIN.
-- Colportores de becas: b1 (Verano, Invierno y Terminada) b2 (Verano sin beca) b3 (Verano, inscripción de baja)
--   b4 (Verano COMPLETA) b5 (Verano MEDIA) b6 (Permanente, sin carrera) b7 (Verano COMPLETA e Invierno MEDIA)
--   b8 (Verano MEDIA de antes, sin carrera).
-- Colportores de alquiler: k1 k2 k3 (también en eb) k4 k5.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'bya-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','a2','ad','b1','b2','b3','b4','b5','b6','b7','b8','51','52','53','54','55']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('ad','ADMIN'),
               ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'), ('b4','COLPORTOR'), ('b5','COLPORTOR'),
               ('b6','COLPORTOR'), ('b7','COLPORTOR'), ('b8','COLPORTOR'),
               ('51','COLPORTOR'), ('52','COLPORTOR'), ('53','COLPORTOR'), ('54','COLPORTOR'), ('55','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, alquiler_monto) values
  (pg_temp.u('e1'), 'Verano',     'VERANO',     '2026-08-03', '2099-12-31', pg_temp.u('a1'), null),
  (pg_temp.u('e2'), 'Invierno',   'INVIERNO',   '2100-01-01', null,         pg_temp.u('a2'), null),
  (pg_temp.u('e3'), 'Terminada',  'VERANO',     '2026-04-01', '2026-06-30', pg_temp.u('a1'), null),
  (pg_temp.u('e5'), 'Permanente', 'PERMANENTE', '2026-08-03', null,         pg_temp.u('a1'), null),
  (pg_temp.u('e6'), 'Verano b',   'VERANO',     '2026-08-03', '2099-12-31', pg_temp.u('a1'), null),
  (pg_temp.u('ea'), 'Alquiler A', 'VERANO',     public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('a1'), 150000),
  (pg_temp.u('eb'), 'Alquiler B', 'VERANO',     public.hoy_montevideo() + 40, public.hoy_montevideo() + 90, pg_temp.u('a2'), 100000);

insert into public.carrera (id, nombre) values
  (pg_temp.u('c1'), 'Teología'), (pg_temp.u('c2'), 'Sistemas'), (pg_temp.u('c3'), 'Enfermería'),
  (pg_temp.u('c4'), 'Medicina');
-- Teología: Verano 60/120 libros, Invierno 50/100. Sistemas: Verano 10/20, Invierno 5/10. Enfermería: SOLO Verano,
-- igual que Teología. Medicina: SOLO Invierno.
insert into public.meta_beca (id, carrera_id, tipo_campania, meta_media, meta_completa, meta_media_monto, meta_completa_monto) values
  (pg_temp.u('f1'), pg_temp.u('c1'), 'VERANO',   60, 120, 3000000, 6000000),
  (pg_temp.u('f2'), pg_temp.u('c1'), 'INVIERNO', 50, 100, 2500000, 5000000),
  (pg_temp.u('f3'), pg_temp.u('c2'), 'VERANO',   10,  20,  500000, 1000000),
  (pg_temp.u('f4'), pg_temp.u('c2'), 'INVIERNO',  5,  10,  250000,  500000),
  (pg_temp.u('f5'), pg_temp.u('c3'), 'VERANO',   60, 120, 3000000, 6000000),
  (pg_temp.u('f6'), pg_temp.u('c4'), 'INVIERNO', 30,  60, 1500000, 3000000);

insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), '2026-08-01 10:00-03'),
  (pg_temp.u('e2'), pg_temp.u('b1'), '2026-08-01 10:00-03'),
  (pg_temp.u('e3'), pg_temp.u('b1'), '2026-03-20 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b2'), '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b3'), '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b4'), '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b5'), '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b7'), '2026-08-01 10:00-03'),
  (pg_temp.u('e2'), pg_temp.u('b7'), '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b8'), '2026-08-01 10:00-03'),
  (pg_temp.u('e5'), pg_temp.u('b6'), '2026-08-01 10:00-03'),
  (pg_temp.u('e6'), pg_temp.u('b2'), '2026-08-01 10:00-03');
update public.campania_colportor set deleted_at = '2026-09-15 12:00:00+00'
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b3');
-- La carrera por primera vez (de null a una): no recalcula nada.
update public.usuario set carrera_id = pg_temp.u('c1')
 where id in (pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('b3'), pg_temp.u('b4'), pg_temp.u('b5'), pg_temp.u('b7'));
-- Las becas de antes, como las dejó el servidor (el coordinador las asigna con asignar_beca()).
update public.campania_colportor cc
   set tipo_beca = x.t, meta_libros = x.l, meta_monto_ces = x.m
  from (values ('e1','b1','MEDIA',60,3000000), ('e2','b1','COMPLETA',100,5000000), ('e3','b1','MEDIA',60,3000000),
               ('e1','b3','MEDIA',60,3000000), ('e1','b4','COMPLETA',120,6000000), ('e1','b5','MEDIA',60,3000000),
               ('e1','b7','COMPLETA',120,6000000), ('e2','b7','MEDIA',50,2500000), ('e1','b8','MEDIA',1,1),
               ('e6','b2','MEDIA',60,3000000)) x(c, u, t, l, m)
 where cc.campania_id = pg_temp.u(x.c) and cc.usuario_id = pg_temp.u(x.u);

-- Alquiler: k1 k2 k3 k4 en ea; k3 también en eb.
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  (pg_temp.u('ea'), pg_temp.u('51'), now() - interval '10 days'),
  (pg_temp.u('ea'), pg_temp.u('52'), now() - interval '10 days'),
  (pg_temp.u('ea'), pg_temp.u('53'), now() - interval '10 days'),
  (pg_temp.u('ea'), pg_temp.u('54'), now() - interval '10 days'),
  (pg_temp.u('eb'), pg_temp.u('53'), now() - interval '10 days');

-- ===========================================================================
-- A. «Beca perman.»: en una campaña permanente no hay becas
-- ===========================================================================
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.error_de($$ select * from public.asignar_beca('01920000-0000-7000-8000-0000000132e5', array['01920000-0000-7000-8000-0000000132b6']::uuid[], 'MEDIA') $$),
          'BC006: En una campaña permanente no hay becas.', 'asignar: media beca en una permanente se rechaza con su texto');
select is(pg_temp.cod($$ select * from public.asignar_beca('01920000-0000-7000-8000-0000000132e5', array['01920000-0000-7000-8000-0000000132b6']::uuid[], 'COMPLETA') $$),
          'BC006', 'asignar: beca completa en una permanente, también');
select is(pg_temp.cod($$ select * from public.asignar_beca('01920000-0000-7000-8000-0000000132e5', array['01920000-0000-7000-8000-0000000132b1']::uuid[], 'MEDIA') $$),
          'BC006', 'asignar: BC006 antes que «el colportor no está en la campaña» (CZ003)');
select is(pg_temp.cod($$ select * from public.asignar_beca('01920000-0000-7000-8000-0000000132e5', array['01920000-0000-7000-8000-0000000132b6']::uuid[], 'X') $$),
          '22023', 'asignar: un tipo inválido sigue dando 22023 también en una permanente');
select is(pg_temp.asig('e5', array['b6'], null), 'b6:-:-:-:N', '«sin beca» sí se puede en una permanente (es lo único que hay)');
select is(pg_temp.beca('e5', 'b6'), '-|-|-', 'y nada cambió en la inscripción');
-- La API directa: el coordinador puede hacer UPDATE de su inscripción (0003); el servidor también.
select is(pg_temp.cod($$ update public.campania_colportor set tipo_beca = 'MEDIA'
            where campania_id = '01920000-0000-7000-8000-0000000132e5' and usuario_id = '01920000-0000-7000-8000-0000000132b6' $$),
          'BC006', 'UPDATE directo del coordinador: tipo de beca en una permanente = BC006');
select pg_temp.actuar_como_servidor();
select is(pg_temp.cod($$ update public.campania_colportor set tipo_beca = 'COMPLETA', meta_libros = 5
            where campania_id = '01920000-0000-7000-8000-0000000132e5' and usuario_id = '01920000-0000-7000-8000-0000000132b6' $$),
          'BC006', 'UPDATE directo del servidor: también');
select is(pg_temp.beca('e5', 'b6'), '-|-|-', 'la inscripción sigue sin beca');
select is(pg_temp.cod($$ update public.campania_colportor set tipo_beca = null
            where campania_id = '01920000-0000-7000-8000-0000000132e5' and usuario_id = '01920000-0000-7000-8000-0000000132b6' $$),
          'ok', 'dejarla sin beca de nuevo es un UPDATE que pasa');
select is(pg_temp.cod($$ insert into public.campania_colportor (campania_id, usuario_id, tipo_beca)
            values ('01920000-0000-7000-8000-0000000132e5', '01920000-0000-7000-8000-0000000132b2', 'MEDIA') $$),
          'BC006', 'una inscripción nueva con beca en una permanente tampoco entra');
-- Lo que ya hubiera no se toca: e6 era de Verano con beca y pasó a permanente.
update public.campania set tipo = 'PERMANENTE' where id = pg_temp.u('e6');
select is(pg_temp.cod($$ update public.campania_colportor set tipo_beca = 'MEDIA'
            where campania_id = '01920000-0000-7000-8000-0000000132e6' and usuario_id = '01920000-0000-7000-8000-0000000132b2' $$),
          'ok', 'repetir el mismo tipo en una beca de antes no se rechaza');
select is(pg_temp.cod($$ update public.campania_colportor set meta_libros = 61
            where campania_id = '01920000-0000-7000-8000-0000000132e6' and usuario_id = '01920000-0000-7000-8000-0000000132b2' $$),
          'ok', 'ni tocar otra columna');
select is(pg_temp.cod($$ update public.campania_colportor set tipo_beca = 'COMPLETA'
            where campania_id = '01920000-0000-7000-8000-0000000132e6' and usuario_id = '01920000-0000-7000-8000-0000000132b2' $$),
          'BC006', 'pero cambiarlo a otro tipo sí');
select ok(not has_function_privilege('authenticated', 'public.tg_campania_colportor_sin_beca_en_permanente()', 'execute'),
          'la función del trigger no la ejecuta nadie con JWT');

-- ===========================================================================
-- B. «Carrera corr»: corregir la carrera recalcula la meta
-- ===========================================================================
select is(pg_temp.beca('e1', 'b1') || '/' || pg_temp.beca('e2', 'b1') || '/' || pg_temp.beca('e3', 'b1'),
          'MEDIA|60|3000000/COMPLETA|100|5000000/MEDIA|60|3000000', 'antes: b1 con Teología en Verano, Invierno y Terminada');
create temp table antes_b on commit drop as
  select cc.usuario_id, cc.campania_id, cc.sync_version from public.campania_colportor cc;
grant select on antes_b to public;

select pg_temp.actuar_como(pg_temp.u('ad'));
select is((select r.cambio from public.elegir_carrera(pg_temp.u('e1'), pg_temp.u('b1'), pg_temp.u('c2')) r), true,
          'el ADMIN corrige la carrera de b1: Teología a Sistemas');
select is(pg_temp.carrera_de('b1'), 'c2', 'b1 queda con Sistemas');
select is(pg_temp.beca('e1', 'b1'), 'MEDIA|10|500000', 'e1: la media beca toma la meta de Verano de Sistemas');
select is(pg_temp.beca('e2', 'b1'), 'COMPLETA|10|500000', 'e2: la beca completa toma la meta de Invierno de Sistemas');
select is(pg_temp.beca('e3', 'b1'), 'MEDIA|60|3000000', 'e3 (terminada): queda como estaba');
select is(pg_temp.beca('e1', 'b3'), 'MEDIA|60|3000000', 'la inscripción de baja de b3 no se toca (y su carrera no cambió)');
select is(pg_temp.n_ev('meta_de_beca_recalculada', 'e1', 'b1') || '/' || pg_temp.n_ev('meta_de_beca_recalculada', 'e2', 'b1')
          || '/' || pg_temp.n_ev('meta_de_beca_recalculada', 'e3', 'b1'), '1/1/0',
          'queda un evento meta_de_beca_recalculada por cada inscripción que cambió');
select is(pg_temp.n_ev('beca_asignada', 'e1', 'b1'), 2, 'y el cambio de la meta también deja beca_asignada (la de antes y la nueva)');
select is(pg_temp.meta_ev('e1', 'b1') @> jsonb_build_object(
            'carrera_anterior', pg_temp.u('c1'), 'carrera_nueva', pg_temp.u('c2'), 'tipo_beca', 'MEDIA',
            'meta_libros_anterior', 60, 'meta_libros', 10, 'meta_monto_ces_anterior', 3000000, 'meta_monto_ces', 500000,
            'campania_id', pg_temp.u('e1')), true,
          'el evento dice carrera anterior y nueva, tipo y las metas de antes y de después');
select is((select array(select k from jsonb_object_keys(pg_temp.meta_ev('e1', 'b1')) k order by k collate "C")),
          array['campania_id','carrera_anterior','carrera_nueva','meta_libros','meta_libros_anterior',
                'meta_monto_ces','meta_monto_ces_anterior','tipo_beca'],
          'el evento lleva solo ids, tipo y números');
select is(pg_temp.n_actor('e1', 'b1', pg_temp.u('ad')), 1, 'el actor es el ADMIN que corrigió');
select is(pg_temp.versiones_distintas(), 0, 'ninguna otra inscripción subió de versión');

-- La lectura de Becas devuelve la marca para el aviso «Carrera corregida: meta de <carrera>».
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.marca('e1', 'b1') || '/' || pg_temp.marca('e1', 'b2') || '/' || pg_temp.marca('e1', 'b4'),
          'true/false/false', 'Becas: marca a b1 (recalculada), no a b2 (sin beca) ni a b4 (carrera sin corregir)');
select is((select r.carrera_nombre from public.becas_de_campania(pg_temp.u('e1')) r where r.usuario_id = pg_temp.u('b1')),
          'Sistemas', 'y la carrera para el texto del aviso es la nueva');
-- Volver a asignar el mismo tipo no cambia nada: la marca sigue. Cambiarlo, sí.
select is(pg_temp.asig('e1', array['b1'], 'MEDIA'), 'b1:MEDIA:10:500000:N', 'reasignar la misma media beca no cambia nada');
select is(pg_temp.marca('e1', 'b1'), 'true', 'la marca sigue');
select is(pg_temp.asig('e1', array['b1'], 'COMPLETA'), 'b1:COMPLETA:20:1000000:S', 'pasarla a completa cambia la meta');
select is(pg_temp.marca('e1', 'b1'), 'false', 'y la marca ya no está: la meta no es la recalculada');

-- b4: corrección a Sistemas, y después la coordinadora vuelve a asignar su mismo tipo.
select pg_temp.actuar_como(pg_temp.u('ad'));
select is((select r.cambio from public.elegir_carrera(pg_temp.u('e1'), pg_temp.u('b4'), pg_temp.u('c2')) r), true, 'b4: Teología a Sistemas');
select is(pg_temp.beca('e1', 'b4'), 'COMPLETA|20|1000000', 'b4: la completa de Verano de Sistemas');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.asig('e1', array['b4'], 'COMPLETA'), 'b4:COMPLETA:20:1000000:N', 'b4: reasignar su mismo tipo no cambia nada');
select is(pg_temp.marca('e1', 'b4'), 'true', 'b4: la marca sigue');

-- b5: la carrera nueva tiene las MISMAS metas: no hay escritura ni evento.
select pg_temp.actuar_como(pg_temp.u('ad'));
select is((select r.cambio from public.elegir_carrera(pg_temp.u('e1'), pg_temp.u('b5'), pg_temp.u('c3')) r), true, 'b5: Teología a Enfermería (mismas metas de Verano)');
select is(pg_temp.carrera_de('b5'), 'c3', 'b5 queda con Enfermería');
select is(pg_temp.beca('e1', 'b5'), 'MEDIA|60|3000000', 'b5: la meta es la misma');
select is(pg_temp.version_igual('e1', 'b5'), true, 'b5: la inscripción no se tocó (misma versión)');
select is(pg_temp.n_ev('meta_de_beca_recalculada', 'e1', 'b5'), 0, 'b5: ningún evento');

-- b7: Medicina solo tiene Invierno; b7 tiene beca en Verano: no se corrige, no cambia nada.
select is(pg_temp.error_de($$ select * from public.elegir_carrera('01920000-0000-7000-8000-0000000132e1', '01920000-0000-7000-8000-0000000132b7', '01920000-0000-7000-8000-0000000132c4') $$),
          'BC004: La carrera nueva no tiene la meta cargada para la campaña de este colportor. Cargala primero y volvé a corregir la carrera.',
          'b7: sin la meta de Verano de Medicina, la corrección se rechaza con su aviso');
select is(pg_temp.carrera_de('b7'), 'c1', 'b7 conserva Teología');
select is(pg_temp.beca('e1', 'b7') || '/' || pg_temp.beca('e2', 'b7'), 'COMPLETA|120|6000000/MEDIA|50|2500000',
          'y sus becas, como estaban (ni siquiera la de Invierno, que sí tenía meta)');
select is(pg_temp.n_ev('meta_de_beca_recalculada', 'e1', 'b7') + pg_temp.n_ev('meta_de_beca_recalculada', 'e2', 'b7'), 0,
          'sin eventos de recálculo');

-- b8: una beca de antes SIN carrera: al elegirla por primera vez toma la meta de la carrera (de ninguna a una).
select is((select r.cambio from public.elegir_carrera(pg_temp.u('e1'), pg_temp.u('b8'), pg_temp.u('c1')) r), true, 'b8: elige carrera por primera vez');
select is(pg_temp.beca('e1', 'b8'), 'MEDIA|60|3000000', 'b8: la meta de antes (1|1) pasa a la de su carrera');
select is(pg_temp.n_ev('meta_de_beca_recalculada', 'e1', 'b8'), 1, 'b8: con su evento');
select is((pg_temp.meta_ev('e1', 'b8') ->> 'carrera_anterior') is null and (pg_temp.meta_ev('e1', 'b8') ->> 'carrera_nueva') = pg_temp.u('c1')::text, true,
          'b8: el evento dice que antes no tenía carrera');

-- Corregir en dos pasos (S1 de la revisión): el ADMIN la quita y el coordinador elige otra. b7 tiene COMPLETA en
-- Verano (e1, de a1) y MEDIA en Invierno (e2, de a2): las dos toman la meta de la carrera nueva.
select pg_temp.actuar_como(pg_temp.u('ad'));
update public.usuario set carrera_id = null where id = pg_temp.u('b7');
select is(pg_temp.beca('e1', 'b7') || '/' || pg_temp.beca('e2', 'b7'), 'COMPLETA|120|6000000/MEDIA|50|2500000', 'quitar la carrera no toca nada');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.error_de($$ select * from public.elegir_carrera('01920000-0000-7000-8000-0000000132e1', '01920000-0000-7000-8000-0000000132b7', '01920000-0000-7000-8000-0000000132c4') $$),
          'BC004: Falta configurar la meta de esta carrera. Avisale al administrador para que la cargue y volvé a asignar la beca.',
          'S1: si la carrera nueva no tiene la meta, el coordinador recibe el aviso de asignar_beca (BC004)');
select is(pg_temp.carrera_de('b7') || '/' || pg_temp.beca('e1', 'b7'), '-/COMPLETA|120|6000000', 'y no cambia nada: ni la carrera ni la beca');
select is((select r.cambio from public.elegir_carrera(pg_temp.u('e1'), pg_temp.u('b7'), pg_temp.u('c2')) r), true, 'S1: a1 elige Sistemas');
select is(pg_temp.carrera_de('b7'), 'c2', 'b7 queda con Sistemas');
select is(pg_temp.beca('e1', 'b7') || '/' || pg_temp.beca('e2', 'b7'), 'COMPLETA|20|1000000/MEDIA|5|250000',
          'S1: Verano y también Invierno, que a1 no coordina, toman la meta de Sistemas');
select is(pg_temp.n_ev('meta_de_beca_recalculada', 'e1', 'b7') || '/' || pg_temp.n_ev('meta_de_beca_recalculada', 'e2', 'b7'), '1/1',
          'S1: un evento por inscripción');
select is(pg_temp.marca('e1', 'b7'), 'true', 'S1: Becas devuelve la marca del aviso');
select is(current_setting('colportores.recalculo_de_metas', true), 'off', 'la bandera del recálculo no queda puesta');
select pg_temp.actuar_como_servidor();

-- La corrección directa (el servidor, el editor SQL) hace lo mismo: b1 vuelve a Teología.
select pg_temp.actuar_como_servidor();
update public.usuario set carrera_id = pg_temp.u('c1') where id = pg_temp.u('b1');
select is(pg_temp.beca('e1', 'b1') || '/' || pg_temp.beca('e2', 'b1') || '/' || pg_temp.beca('e3', 'b1'),
          'COMPLETA|120|6000000/COMPLETA|100|5000000/MEDIA|60|3000000', 'por UPDATE directo: Verano e Invierno recalculan, la terminada no');
select is(pg_temp.n_ev('meta_de_beca_recalculada', 'e1', 'b1') || '/' || pg_temp.n_ev('meta_de_beca_recalculada', 'e2', 'b1'), '2/2',
          'y cada cambio de meta dejó su evento');
select is(pg_temp.n_actor('e2', 'b1', null), 1, 'sin sesión, el actor del segundo evento queda null');
-- Dejar la carrera sin valor no recalcula (no hay meta que tomar).
update public.usuario set carrera_id = null where id = pg_temp.u('b2');
select is(pg_temp.beca('e1', 'b2'), '-|-|-', 'quitar la carrera no inventa ninguna meta');
-- La primera elección de quien no tiene beca viva (b2: la de e6 está en una permanente) no recalcula nada.
update public.usuario set carrera_id = pg_temp.u('c2') where id = pg_temp.u('b2');
select is((select count(*)::int from auditoria.audit_log where event_type = 'meta_de_beca_recalculada'
              and target_user_id = pg_temp.u('b2')), 0, 'elegir la carrera por primera vez sin beca viva no deja ningún evento');
select ok(not has_function_privilege('authenticated', 'public.tg_usuario_carrera_recalcula_metas()', 'execute'),
          'la función del trigger no la ejecuta nadie con JWT');

-- ===========================================================================
-- C y D. Alquiler: la tabla guardada, quien se da de baja y la lectura de Cuentas
-- ===========================================================================
-- La forma.
select has_table('public', 'cuenta_alquiler', 'existe cuenta_alquiler');
select is((select relrowsecurity from pg_class where oid = 'public.cuenta_alquiler'::regclass), true, 'tiene RLS');
select ok(has_table_privilege('authenticated', 'public.cuenta_alquiler', 'select')
          and not has_table_privilege('authenticated', 'public.cuenta_alquiler', 'insert')
          and not has_table_privilege('authenticated', 'public.cuenta_alquiler', 'update')
          and not has_table_privilege('authenticated', 'public.cuenta_alquiler', 'delete')
          and not has_table_privilege('anon', 'public.cuenta_alquiler', 'select'),
          'authenticated solo lee; anon, nada');
select is((select array(select conname::text || ':' || confdeltype::text from pg_constraint
                         where conrelid = 'public.cuenta_alquiler'::regclass and contype = 'f'
                           and conname not like '%created_by%' order by conname)),
          array['cuenta_alquiler_campania_id_fkey:c', 'cuenta_alquiler_usuario_id_fkey:c'],
          'las FK a persona y a campaña borran en cascada: es un derivado');
select is((select array(select pg_get_constraintdef(oid) from pg_constraint
                         where conrelid = 'public.cuenta_alquiler'::regclass and contype = 'u')),
          array['UNIQUE (usuario_id, campania_id)'], 'una fila por persona y campaña');
select ok(not has_function_privilege('authenticated', 'public.alquiler_calculado(uuid, uuid)', 'execute')
          and not has_function_privilege('authenticated', 'public.refrescar_cuenta_alquiler(uuid, uuid)', 'execute')
          and not has_function_privilege('service_role', 'public.alquiler_calculado(uuid, uuid)', 'execute')
          and has_function_privilege('authenticated', 'public.cuentas_de_campania(uuid)', 'execute')
          and not has_function_privilege('anon', 'public.cuentas_de_campania(uuid)', 'execute'),
          'las piezas internas no se ejecutan con JWT; cuentas_de_campania, solo authenticated');

-- Las inscripciones que ya estaban tienen su fila desde el principio.
select is(pg_temp.fila('51', 'ea'), '150000|0|0|150000|0', 'k1 en ea: debe todo el alquiler');
select is(pg_temp.fila('53', 'eb'), '100000|0|0|100000|0', 'k3 en eb: el alquiler de la otra campaña');
select is(pg_temp.fila('b1', 'e1'), 'n|0|0|n|0', 'una campaña que no cobra: debe null');
select is(pg_temp.coincide('ea'), '4|0', 'ea: cuatro filas y la tabla coincide con cuentas_de_campania()');
select is(pg_temp.coincide('eb'), '1|0', 'eb: una fila y coincide');

-- Un retiro sin ticket, por validar.
insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id) values
  (pg_temp.u('d1'), pg_temp.u('51'), 20000, now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('ea'));
select is(pg_temp.fila('51', 'ea'), '150000|0|20000|150000|0', 'un depósito de alquiler nuevo: queda por validar');
select is(pg_temp.coincide('ea'), '4|0', '  … y coincide');
-- Un depósito con su ticket pendiente.
insert into public.ticket (id, usuario_id, tipo, monto, fecha, estado) values
  (pg_temp.u('11'), pg_temp.u('51'), 'DEPOSITO', 50000, now(), 'PENDIENTE'),
  (pg_temp.u('12'), pg_temp.u('51'), 'DEPOSITO', 30000, now(), 'PENDIENTE'),
  (pg_temp.u('13'), pg_temp.u('51'), 'DEPOSITO', 200000, now(), 'PENDIENTE');
insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id) values
  (pg_temp.u('d2'), pg_temp.u('51'), 50000, now(), pg_temp.u('11'), 'BANCO', 'ALQUILER', pg_temp.u('ea'));
select is(pg_temp.fila('51', 'ea'), '150000|0|70000|150000|0', 'con un ticket pendiente: por validar 70000');
-- Validar el ticket lo acredita en la misma transacción.
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select v.estado from public.validar_ticket(pg_temp.u('11')) v), 'VALIDADO', 'a1 valida el ticket de 50000');
select pg_temp.actuar_como_servidor();
select is(pg_temp.fila('51', 'ea'), '150000|50000|20000|100000|0', 'validar acredita: pagado 50000, debe 100000');
select is((select ca.alquiler_ultimo_pago_fecha is not null from public.cuenta_alquiler ca
            where ca.usuario_id = pg_temp.u('51') and ca.campania_id = pg_temp.u('ea')), true, 'y se guarda la fecha del último pago');
select is(pg_temp.coincide('ea'), '4|0', '  … y coincide');
-- Confirmar el retiro.
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select v.estado from public.confirmar_retiro(pg_temp.u('d1')) v), 'VALIDADO', 'a1 confirma el retiro de 20000');
select pg_temp.actuar_como_servidor();
select is(pg_temp.fila('51', 'ea'), '150000|70000|0|80000|0', 'el retiro confirmado suma a lo pagado');
select is(pg_temp.coincide('ea'), '4|0', '  … y coincide');
-- Un ticket rechazado deja de estar por validar.
insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id) values
  (pg_temp.u('d3'), pg_temp.u('51'), 30000, now(), pg_temp.u('12'), 'BANCO', 'ALQUILER', pg_temp.u('ea'));
select is(pg_temp.fila('51', 'ea'), '150000|70000|30000|80000|0', 'otro ticket pendiente: por validar 30000');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select r.estado from public.rechazar_ticket(pg_temp.u('12'), 'No se lee el monto') r), 'RECHAZADO', 'a1 rechaza el ticket');
select pg_temp.actuar_como_servidor();
select is(pg_temp.fila('51', 'ea'), '150000|70000|0|80000|0', 'rechazado: ya no está por validar y no se pagó nada');
select is(pg_temp.coincide('ea'), '4|0', '  … y coincide');
-- Pagar de más deja el excedente a favor.
insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id) values
  (pg_temp.u('d4'), pg_temp.u('51'), 200000, now(), pg_temp.u('13'), 'BANCO', 'ALQUILER', pg_temp.u('ea'));
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select v.estado from public.validar_ticket(pg_temp.u('13')) v), 'VALIDADO', 'a1 valida los 200000');
select pg_temp.actuar_como_servidor();
select is(pg_temp.fila('51', 'ea'), '150000|270000|0|0|120000', 'pagó de más: no debe y le quedan 120000 a favor');
select is(pg_temp.coincide('ea'), '4|0', '  … y coincide');

-- «Alq. de baja»: quien se da de baja debe 0 y lo pagado queda a favor; al reactivar vuelve a deber.
insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id) values
  (pg_temp.u('d5'), pg_temp.u('52'), 40000, now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('ea'));
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select v.estado from public.confirmar_retiro(pg_temp.u('d5')) v), 'VALIDADO', 'a1 confirma los 40000 de k2');
select pg_temp.actuar_como_servidor();
select is(pg_temp.fila('52', 'ea'), '150000|40000|0|110000|0', 'k2 inscripta: debe 110000');
update public.campania_colportor set deleted_at = now()
 where campania_id = pg_temp.u('ea') and usuario_id = pg_temp.u('52');
select is(pg_temp.fila('52', 'ea'), '150000|40000|0|0|40000', 'k2 de baja: debe 0 y los 40000 quedan a favor');
select is(pg_temp.coincide('ea'), '4|0', '  … y coincide (la baja sigue en la lista)');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select format('%s|%s|%s|%s', r.de_baja, r.alquiler_debe, r.alquiler_pagado, r.alquiler_trasladado)
             from public.cuentas_de_campania(pg_temp.u('ea')) r where r.colportor_id = pg_temp.u('52')),
          't|0|40000|40000', 'Cuentas: de baja, debe 0, pagado 40000 y a favor 40000');
select pg_temp.actuar_como_servidor();
update public.campania_colportor set deleted_at = null
 where campania_id = pg_temp.u('ea') and usuario_id = pg_temp.u('52');
select is(pg_temp.fila('52', 'ea'), '150000|40000|0|110000|0', 'reactivada: vuelve a deber el alquiler (contando lo que ya pagó)');
select is(pg_temp.coincide('ea'), '4|0', '  … y coincide');

-- El monto del alquiler de la campaña cambia: se recalculan todos los inscriptos de esa campaña y solo esos.
create temp table antes_eb on commit drop as
  select ca.usuario_id, ca.campania_id, ca.sync_version from public.cuenta_alquiler ca;
grant select on antes_eb to public;
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select r.cambio from public.definir_alquiler_de_campania(pg_temp.u('ea'), 180000) r), true, 'a1 sube el alquiler de ea a 180000');
select pg_temp.actuar_como_servidor();
select is(pg_temp.fila('51', 'ea') || '/' || pg_temp.fila('52', 'ea') || '/' || pg_temp.fila('54', 'ea'),
          '180000|270000|0|0|90000/180000|40000|0|140000|0/180000|0|0|180000|0', 'el monto nuevo llega a todas las filas de ea');
select is(pg_temp.coincide('ea'), '4|0', '  … y coincide');
select is((select ca.sync_version = a.sync_version from public.cuenta_alquiler ca join antes_eb a using (usuario_id, campania_id)
            where ca.usuario_id = pg_temp.u('53') and ca.campania_id = pg_temp.u('eb')), true, 'la fila de eb no se tocó');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select r.cambio from public.definir_alquiler_de_campania(pg_temp.u('ea'), null) r), true, 'a1 deja ea sin alquiler');
select pg_temp.actuar_como_servidor();
select is(pg_temp.fila('51', 'ea') || '/' || pg_temp.fila('52', 'ea'), 'n|270000|0|n|270000/n|40000|0|n|40000',
          'sin alquiler: no debe (null) y todo lo pagado queda a favor');
update public.campania_colportor set deleted_at = now() where campania_id = pg_temp.u('ea') and usuario_id = pg_temp.u('52');
select is(pg_temp.fila('52', 'ea'), 'n|40000|0|n|40000', 'de baja en una campaña que no cobra: sigue null');
select is(pg_temp.coincide('ea'), '4|0', '  … y coincide');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select r.cambio from public.definir_alquiler_de_campania(pg_temp.u('ea'), 150000) r), true, 'a1 vuelve a 150000');
select pg_temp.actuar_como_servidor();
select is(pg_temp.fila('52', 'ea'), '150000|40000|0|0|40000', 'con alquiler otra vez, k2 sigue de baja: debe 0');
update public.campania_colportor set deleted_at = null where campania_id = pg_temp.u('ea') and usuario_id = pg_temp.u('52');
select pg_temp.actuar_como(pg_temp.u('a2'));
select is((select r.cambio from public.definir_alquiler_de_campania(pg_temp.u('eb'), 120000) r), true, 'a2 cambia el alquiler de eb');
select pg_temp.actuar_como_servidor();
select is(pg_temp.fila('53', 'eb') || '/' || pg_temp.fila('53', 'ea'), '120000|0|0|120000|0/150000|0|0|150000|0',
          'k3: el cambio de eb no toca su cuenta de ea');

-- Un depósito que se da de baja, que cambia de campaña, uno de casa editora y un cambio que no cambia nada.
insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id) values
  (pg_temp.u('d6'), pg_temp.u('54'), 10000, now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('ea')),
  (pg_temp.u('d7'), pg_temp.u('53'), 15000, now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('ea'));
select is(pg_temp.fila('54', 'ea'), '150000|0|10000|150000|0', 'k4: un depósito por validar');
update public.deposito set deleted_at = now() where id = pg_temp.u('d6');
select is(pg_temp.fila('54', 'ea'), '150000|0|0|150000|0', 'dado de baja el depósito, deja de contar');
select is(pg_temp.fila('53', 'ea'), '150000|0|15000|150000|0', 'k3: 15000 por validar en ea');
update public.deposito set campania_id = pg_temp.u('eb') where id = pg_temp.u('d7');
select is(pg_temp.fila('53', 'ea') || '/' || pg_temp.fila('53', 'eb'), '150000|0|0|150000|0/120000|0|15000|120000|0',
          'pasó a la otra campaña: se descuenta de ea y se suma a eb');
select is(pg_temp.coincide('ea') || '/' || pg_temp.coincide('eb'), '4|0/1|0', '  … y las dos coinciden');
create temp table antes_c on commit drop as
  select ca.usuario_id, ca.campania_id, ca.sync_version from public.cuenta_alquiler ca;
grant select on antes_c to public;
insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id) values
  (pg_temp.u('d8'), pg_temp.u('51'), 99000, now(), null, 'RETIRO_COORDINADOR', 'CASA_EDITORA', null);
update public.deposito set fecha = fecha where id = pg_temp.u('d1');
select is((select count(*)::int from public.cuenta_alquiler ca join antes_c a using (usuario_id, campania_id)
            where ca.sync_version <> a.sync_version), 0,
          'un depósito de casa editora o un cambio que no cambia nada no escribe ninguna fila (ni sube la versión)');

-- Una inscripción nueva nace con lo que esa persona ya había pagado en la campaña.
insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id, validado_en, validado_por) values
  (pg_temp.u('d9'), pg_temp.u('55'), 30000, now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('ea'), now(), pg_temp.u('a1'));
select is(pg_temp.fila('55', 'ea'), 'sin fila', 'sin inscripción no hay fila (el depósito suelto no la crea)');
insert into public.campania_colportor (campania_id, usuario_id, created_at) values (pg_temp.u('ea'), pg_temp.u('55'), now() - interval '5 days');
select is(pg_temp.fila('55', 'ea'), '150000|30000|0|120000|0', 'al inscribirse aparece su fila, con lo ya pagado');
select is(pg_temp.coincide('ea'), '5|0', '  … y ea tiene cinco filas que coinciden');

-- El push del teléfono: el colportor sube su depósito de alquiler y la cuenta se mueve en la misma transacción.
select pg_temp.actuar_como(pg_temp.u('51'));
select is(pg_temp.push1(pg_temp.u('01'), 'deposito', 'insert',
            jsonb_build_object('id', pg_temp.u('da'), 'monto', 7000, 'fecha', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                               'destino', 'RETIRO_COORDINADOR', 'concepto', 'ALQUILER', 'campania_id', pg_temp.u('ea'))) ->> 'outcome',
          'accepted', 'el push acepta el depósito de alquiler');
select pg_temp.actuar_como_servidor();
select is(pg_temp.fila('51', 'ea'), '150000|270000|7000|0|120000', 'y queda por validar en su cuenta');
select pg_temp.actuar_como(pg_temp.u('51'));
select is(pg_temp.push1(pg_temp.u('01'), 'deposito', 'insert',
            jsonb_build_object('id', pg_temp.u('da'), 'monto', 7000, 'fecha', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                               'destino', 'RETIRO_COORDINADOR', 'concepto', 'ALQUILER', 'campania_id', pg_temp.u('ea'))) ->> 'outcome',
          'duplicate', 'el mismo push repetido es un reintento (duplicate)');
select pg_temp.actuar_como_servidor();
select is(pg_temp.fila('51', 'ea'), '150000|270000|7000|0|120000', 'y no suma dos veces');
select is(pg_temp.coincide('ea'), '5|0', '  … y coincide');

-- La vista previa de validar un ticket usa la misma cuenta: quien está de baja no debe nada.
update public.campania_colportor set deleted_at = now() where campania_id = pg_temp.u('ea') and usuario_id = pg_temp.u('52');
insert into public.ticket (id, usuario_id, tipo, monto, fecha, estado) values
  (pg_temp.u('14'), pg_temp.u('52'), 'DEPOSITO', 50000, now() - interval '1 hour', 'PENDIENTE'),
  (pg_temp.u('15'), pg_temp.u('51'), 'DEPOSITO', 50000, now() - interval '1 hour', 'PENDIENTE');
insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id) values
  (pg_temp.u('db'), pg_temp.u('52'), 50000, now() - interval '1 hour', pg_temp.u('14'), 'BANCO', 'ALQUILER', pg_temp.u('ea')),
  (pg_temp.u('dc'), pg_temp.u('51'), 50000, now() - interval '1 hour', pg_temp.u('15'), 'BANCO', 'ALQUILER', pg_temp.u('ea'));
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select format('%s|%s|%s|%s', v.deuda_antes, v.deuda_despues, v.supera_deuda, v.a_favor_despues)
             from public.validacion_de_ticket(pg_temp.u('14')) v),
          '0|0|50000|0', 'de baja: no debe nada (antes 0) y los 50000 superan la deuda: desde 0152 pasan a la deuda con la casa editora, no quedan a favor del alquiler');
select is((select format('%s|%s|%s|%s', v.deuda_antes, v.deuda_despues, v.supera_deuda, v.a_favor_despues)
             from public.validacion_de_ticket(pg_temp.u('15')) v),
          '0|0|50000|0', 'inscripta y con todo pagado: los 50000 también pasan a la deuda con la casa editora (0152)');
select is((select v.estado from public.validar_ticket(pg_temp.u('14')) v), 'VALIDADO', 'a1 valida el de la persona de baja');
select pg_temp.actuar_como_servidor();
select is(pg_temp.fila('52', 'ea'), '150000|90000|0|0|90000', 'de baja, con lo pagado: debe 0 y 90000 a favor');
select is(pg_temp.coincide('ea'), '5|0', '  … y coincide');

-- --- quién la lee ----------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('53'));
select is((select count(*)::int from public.cuenta_alquiler), 2, 'k3 ve sus dos cuentas (ea y eb)');
select pg_temp.actuar_como(pg_temp.u('54'));
select is((select count(*)::int from public.cuenta_alquiler), 1, 'k4 ve solo la suya');
select is((select count(*)::int from public.cuenta_alquiler where usuario_id <> pg_temp.u('54')), 0, 'y ninguna ajena');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select count(*)::int from public.cuenta_alquiler where campania_id = pg_temp.u('ea')), 5, 'a1 ve las cinco cuentas de su campaña');
select is((select count(*)::int from public.cuenta_alquiler where campania_id = pg_temp.u('eb')), 0,
          'y no ve la de k3 en la campaña de otro coordinador');
select pg_temp.actuar_como(pg_temp.u('a2'));
select is((select count(*)::int from public.cuenta_alquiler where campania_id in (pg_temp.u('ea'), pg_temp.u('eb'))), 1,
          'a2 ve solo la de eb (de ea, ninguna)');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is((select count(*)::int from public.cuenta_alquiler where campania_id in (pg_temp.u('ea'), pg_temp.u('eb'))), 6, 'el ADMIN ve todas');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.cod($$ insert into public.cuenta_alquiler (usuario_id, campania_id) values ('01920000-0000-7000-8000-0000000132b1', '01920000-0000-7000-8000-0000000132ea') $$),
          '42501', 'nadie con JWT escribe la tabla: insert');
select is(pg_temp.cod($$ update public.cuenta_alquiler set alquiler_pagado = 1 $$), '42501', 'update');
select is(pg_temp.cod($$ delete from public.cuenta_alquiler $$), '42501', 'delete');
select pg_temp.actuar_como_anon();
select is(pg_temp.cod($$ select * from public.cuenta_alquiler $$), '42501', 'anon no la lee');
select is(pg_temp.cod($$ select * from public.cuentas_de_campania('01920000-0000-7000-8000-0000000132ea') $$), '42501', 'ni cuentas_de_campania');
select pg_temp.actuar_como_servidor();

select * from finish();
rollback;
