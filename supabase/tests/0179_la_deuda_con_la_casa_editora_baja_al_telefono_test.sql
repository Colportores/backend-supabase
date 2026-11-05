-- pgTAP · migración 0179 (backend-supabase#254, casilla «Deuda pull»): la deuda con la casa editora baja al teléfono por el sync.
--   1. El registro: `cuenta_colportor` y `cuenta_deuda_historial` son entidades de solo bajada con el dueño en `usuario_id`
--      (sin ubicación ni campañas), con el índice del delta con el dueño primero, sin Realtime; el teléfono no las escribe.
--   2. El pull: cada persona baja SOLO su cuenta y su historial (no los de otra, tampoco un coordinador ni un ADMIN).
--   3. Los casos de backend-supabase#235 (test 0164) calculados sobre lo que baja por el sync: con las filas del pull
--      (cuenta, historial, pedidos, líneas, productos, depósitos y tickets) se rehace el reparto «el más viejo primero» y el
--      resultado es IGUAL al de `mi_deuda_con_la_casa_editora()` (la deuda, la de hace 7 días, la suma de saldos, lo validado en
--      depósitos y en tarjeta, y cada pedido con su pagado, su saldo y sus líneas): reparto con pagos validados, por validar,
--      rechazados y dados de baja; empate de fecha; tarjeta; deuda a favor; cuenta dada de baja; cantidades autorizadas.
--   4. El delta: cuando el servidor mueve la deuda baja la fila nueva, solo a su dueña.
--
-- Como 0145, NO va en una transacción: el delta solo sirve lo commiteado. Limpia al empezar y al final.

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

-- Ids con el prefijo 179: usuarios 179b1.., pedidos 179a1.., productos 17991..
create or replace function pg_temp.u(p_sufijo text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000179' || p_sufijo)::uuid;
$$;

create or replace function pg_temp.limpiar() returns void language plpgsql as $$
declare v uuid[] := array[pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('b3'), pg_temp.u('b4'), pg_temp.u('b7'), pg_temp.u('c1'), pg_temp.u('ad')];
begin
  delete from public.ticket where usuario_id = any (v);
  delete from public.deposito where colportor_id = any (v);
  delete from public.pedido_item where pedido_id in (select id from public.pedido_casa_editora where colportor_id = any (v));
  delete from public.pedido_casa_editora where colportor_id = any (v);
  delete from public.cuenta_deuda_historial where usuario_id = any (v);
  delete from public.cuenta_colportor where usuario_id = any (v);
  delete from public.producto where id in (pg_temp.u('91'), pg_temp.u('92'), pg_temp.u('93'));
  delete from public.usuario_rol where usuario_id = any (v);
  delete from auth.users where id = any (v);
end $$;

-- Como la persona p, el pull de las entidades que el teléfono necesita para calcular la deuda.
create or replace function pg_temp.pull_de(p text) returns jsonb language plpgsql as $$
declare d jsonb;
begin
  perform pg_temp.actuar_como(pg_temp.u(p));
  d := sync.pull(array['cuenta_colportor', 'cuenta_deuda_historial', 'pedido_casa_editora', 'pedido_item', 'producto',
                       'deposito', 'ticket'], '{}'::jsonb, 1000);
  perform pg_temp.como_servidor();
  return d;
end $$;

-- Lo que cambió desde la marca, como la persona p.
create or replace function pg_temp.delta_de(p text, p_marca jsonb) returns jsonb language plpgsql as $$
declare d jsonb;
begin
  perform pg_temp.actuar_como(pg_temp.u(p));
  d := sync.pull(array['cuenta_colportor', 'cuenta_deuda_historial'], p_marca, 1000);
  perform pg_temp.como_servidor();
  return d;
end $$;

create or replace function pg_temp.filas(p_delta jsonb, p_entidad text) returns setof jsonb language sql as $$
  select e from jsonb_array_elements(coalesce(p_delta -> 'rows' -> p_entidad, '[]'::jsonb)) e
$$;

-- LO QUE HARÍA EL TELÉFONO: «deuda|hace 7 días|suma de saldos|depósitos|tarjetas|pedidos» con las filas que bajaron.
-- Cada pedido: «sufijo:monto/pagado/saldo[líneas]», solo los de saldo > 0, del más viejo al más nuevo.
create or replace function pg_temp.en_el_telefono(p_delta jsonb) returns text language sql as $$
  with
  cuenta as (
    select coalesce((select (e ->> 'deuda_total')::bigint from pg_temp.filas(p_delta, 'cuenta_colportor') e
                      where e ->> 'deleted_at' is null limit 1), 0) as deuda),
  hace7 as (
    select (select (e ->> 'deuda')::bigint from pg_temp.filas(p_delta, 'cuenta_deuda_historial') e
             where e ->> 'deleted_at' is null and (e ->> 'desde')::timestamptz <= now() - interval '7 days'
             order by (e ->> 'desde')::timestamptz desc, e ->> 'id' desc limit 1) as deuda),
  deps as (
    select coalesce(sum((e ->> 'monto')::bigint), 0)::bigint as total from pg_temp.filas(p_delta, 'deposito') e
     where e ->> 'deleted_at' is null and e ->> 'concepto' = 'CASA_EDITORA' and e ->> 'validado_en' is not null),
  tarj as (
    select coalesce(sum((e ->> 'monto')::bigint), 0)::bigint as total from pg_temp.filas(p_delta, 'ticket') e
     where e ->> 'deleted_at' is null and e ->> 'tipo' = 'COBRO_TARJETA' and e ->> 'estado' = 'VALIDADO'),
  pedidos as (
    select e ->> 'id' as id, (e ->> 'numero')::bigint as numero, (e ->> 'fecha_pedido')::timestamptz as fecha,
           coalesce((e ->> 'monto_autorizado')::bigint, (e ->> 'monto_total')::bigint) as monto
      from pg_temp.filas(p_delta, 'pedido_casa_editora') e
     where e ->> 'deleted_at' is null and e ->> 'estado' in ('AUTORIZADO', 'DESPACHADO', 'RECIBIDO')),
  acum as (
    select p.*, coalesce(sum(p.monto) over (order by p.fecha, p.numero, p.id
                                             rows between unbounded preceding and 1 preceding), 0) as antes
      from pedidos p),
  reparto as (
    select a.*, least(a.monto, greatest((select total from deps) + (select total from tarj) - a.antes, 0)) as pagado
      from acum a),
  con_saldo as (select r.*, r.monto - r.pagado as saldo from reparto r),
  lineas as (
    select i ->> 'pedido_id' as pedido_id, pr ->> 'nombre' as nombre, i ->> 'producto_id' as producto_id,
           coalesce((i ->> 'cantidad_autorizada')::int, (i ->> 'cantidad')::int) as cantidad
      from pg_temp.filas(p_delta, 'pedido_item') i
      join pg_temp.filas(p_delta, 'producto') pr on pr ->> 'id' = i ->> 'producto_id'
     where i ->> 'deleted_at' is null and coalesce((i ->> 'cantidad_autorizada')::int, (i ->> 'cantidad')::int) > 0)
  select format('%s|%s|%s|%s|%s|%s', (select deuda from cuenta), coalesce((select deuda::text from hace7), 'n'),
                coalesce((select sum(saldo) from con_saldo), 0), (select total from deps), (select total from tarj),
                coalesce((select string_agg(format('%s:%s/%s/%s[%s]', right(s.id, 2), s.monto, s.pagado, s.saldo,
                                                   coalesce((select string_agg(l.nombre || ' x' || l.cantidad, ', ' order by l.nombre, l.producto_id)
                                                               from lineas l where l.pedido_id = s.id), '')),
                                            ', ' order by s.fecha, s.numero, s.id)
                            from con_saldo s where s.saldo > 0), '-'))
$$;

-- LO QUE DICE LA RPC (la referencia): el mismo texto, como la persona p.
create or replace function pg_temp.por_rpc(p text) returns text language plpgsql as $$
declare j jsonb; v text;
begin
  perform pg_temp.actuar_como(pg_temp.u(p));
  j := public.mi_deuda_con_la_casa_editora();
  perform pg_temp.como_servidor();
  select format('%s|%s|%s|%s|%s|%s', j ->> 'deuda_total', coalesce(j ->> 'deuda_hace_7_dias', 'n'), j ->> 'suma_de_saldos',
                j ->> 'depositos_validados', j ->> 'tarjetas_validadas',
                coalesce((select string_agg(format('%s:%s/%s/%s[%s]', right(e ->> 'pedido_id', 2), e ->> 'monto', e ->> 'pagado',
                                                   e ->> 'saldo',
                                                   coalesce((select string_agg(l ->> 'nombre' || ' x' || (l ->> 'cantidad'), ', ' order by ord)
                                                               from jsonb_array_elements(e -> 'lineas') with ordinality x(l, ord)), '')),
                                            ', ' order by o)
                            from jsonb_array_elements(j -> 'pedidos') with ordinality t(e, o)), '-'))
    into v;
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- 1. El registro
-- ---------------------------------------------------------------------------
select results_eq(
  $$ select nombre, tabla::text, columna_pk, permite_push, sigue_campanias, columna_ubicacion, columna_duenio
       from sync.entidad where nombre in ('cuenta_colportor', 'cuenta_deuda_historial') order by nombre $$,
  $$ values ('cuenta_colportor'::text, 'cuenta_colportor'::text, 'id'::text, false, false, null::text, 'usuario_id'::text),
            ('cuenta_deuda_historial', 'cuenta_deuda_historial', 'id', false, false, null, 'usuario_id') $$,
  'las dos entidades: de solo bajada, con el dueño en usuario_id y sin filtro por campaña ni ubicación');
select has_index('public', 'cuenta_colportor', 'cuenta_colportor_delta_idx', array['usuario_id', 'xmin_w', 'id'],
                 'cuenta_colportor: el índice del delta, con el dueño primero');
select has_index('public', 'cuenta_deuda_historial', 'cuenta_deuda_historial_delta_idx', array['usuario_id', 'xmin_w', 'id'],
                 'cuenta_deuda_historial: el índice del delta, con el dueño primero');
select is((select count(*)::int from pg_publication_tables
            where pubname = 'supabase_realtime' and schemaname = 'public'
              and tablename in ('cuenta_colportor', 'cuenta_deuda_historial')),
          0, 'ninguna va a Realtime (ADR-012)');
select is((select has_table_privilege('authenticated', 'public.cuenta_colportor', 'insert')
               or has_table_privilege('authenticated', 'public.cuenta_colportor', 'update')
               or has_table_privilege('authenticated', 'public.cuenta_colportor', 'delete')
               or has_table_privilege('authenticated', 'public.cuenta_deuda_historial', 'insert')
               or has_table_privilege('authenticated', 'public.cuenta_deuda_historial', 'update')
               or has_table_privilege('authenticated', 'public.cuenta_deuda_historial', 'delete')),
          false, 'el teléfono no tiene INSERT, UPDATE ni DELETE sobre ninguna');
select is(to_regprocedure('public.mi_deuda_con_la_casa_editora()') is not null, true,
          'la RPC de la 0164 sigue (la app de develop la llama hasta que lea la deuda del sync)');

-- ---------------------------------------------------------------------------
-- Fixtures (los casos de #235, como postgres). b1: el reparto; b2: otra persona (aislamiento); b3: a favor;
-- b4: cuenta dada de baja; b7: líneas; c1 coordinador; ad ADMIN.
-- ---------------------------------------------------------------------------
select pg_temp.limpiar();
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'deuda179-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','b3','b4','b7','c1','ad']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'), ('b4','COLPORTOR'), ('b7','COLPORTOR'),
               ('c1','COORDINADOR'), ('ad','ADMIN')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.producto (id, nombre, tipo, precio_base_compra) values
  (pg_temp.u('91'), 'Libro Uno 179',   'LIBRO',   1500),
  (pg_temp.u('92'), 'Libro Dos 179',   'LIBRO',   2500),
  (pg_temp.u('93'), 'Revista Uno 179', 'REVISTA', 200);

-- b1: a1 AUTORIZADO 02/10 (pedido 26000, autorizado 14000); a2 DESPACHADO 15/10 10000; a3 AUTORIZADO 15/10 (mismo día,
-- número más alto) sin monto autorizado: vale 5000; a4 RECIBIDO 20/10 3000. No cuentan: por autorizar, rechazado,
-- cancelado, borrador y uno autorizado dado de baja.
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, monto_autorizado, origen, fecha_pedido)
values (pg_temp.u('a1'), pg_temp.u('b1'), 'AUTORIZADO', 26000, 14000, 'COLPORTOR', '2026-10-02 10:00:00+00');
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, monto_autorizado, origen, fecha_pedido)
values (pg_temp.u('a2'), pg_temp.u('b1'), 'DESPACHADO', 10000, 10000, 'COLPORTOR', '2026-10-15 10:00:00+00');
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, monto_autorizado, origen, fecha_pedido)
values (pg_temp.u('a3'), pg_temp.u('b1'), 'AUTORIZADO', 5000, null, 'COORDINADOR', '2026-10-15 10:00:00+00');
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, monto_autorizado, origen, fecha_pedido)
values (pg_temp.u('a4'), pg_temp.u('b1'), 'RECIBIDO', 3000, 3000, 'COLPORTOR', '2026-10-20 10:00:00+00');
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, origen, fecha_pedido, motivo_rechazo) values
  (pg_temp.u('a5'), pg_temp.u('b1'), 'PENDIENTE_AUTORIZACION', 7000, 'COLPORTOR',   '2026-10-01 10:00:00+00', null),
  (pg_temp.u('a6'), pg_temp.u('b1'), 'RECHAZADO',               3000, 'COLPORTOR',   '2026-10-01 11:00:00+00', 'Sin cupo'),
  (pg_temp.u('a7'), pg_temp.u('b1'), 'CANCELADO',               1000, 'COLPORTOR',   '2026-10-01 12:00:00+00', null),
  (pg_temp.u('a8'), pg_temp.u('b1'), 'BORRADOR',                2000, 'COORDINADOR', '2026-10-01 13:00:00+00', null);
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, monto_autorizado, origen, fecha_pedido, deleted_at)
values (pg_temp.u('a9'), pg_temp.u('b1'), 'AUTORIZADO', 9000, 9000, 'COLPORTOR', '2026-10-01 14:00:00+00', now());

-- b7: los cuatro pedidos que cuentan, con líneas y sin pagar nada (las líneas en desorden, una dada de baja, una en cero).
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, monto_autorizado, origen, fecha_pedido)
values (pg_temp.u('d1'), pg_temp.u('b7'), 'AUTORIZADO', 26000, 14000, 'COLPORTOR', '2026-10-02 10:00:00+00');
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, monto_autorizado, origen, fecha_pedido)
values (pg_temp.u('d2'), pg_temp.u('b7'), 'DESPACHADO', 10000, 10000, 'COLPORTOR', '2026-10-15 10:00:00+00');
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, monto_autorizado, origen, fecha_pedido)
values (pg_temp.u('d3'), pg_temp.u('b7'), 'AUTORIZADO', 5000, null, 'COORDINADOR', '2026-10-15 10:00:00+00');
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, monto_autorizado, origen, fecha_pedido)
values (pg_temp.u('d4'), pg_temp.u('b7'), 'RECIBIDO', 3000, 3000, 'COLPORTOR', '2026-10-20 10:00:00+00');
insert into public.pedido_item (pedido_id, producto_id, cantidad, precio_unitario, cantidad_autorizada, deleted_at) values
  (pg_temp.u('d1'), pg_temp.u('92'), 4, 2500, 2,    null),
  (pg_temp.u('d1'), pg_temp.u('93'), 5, 200,  0,    null),
  (pg_temp.u('d1'), pg_temp.u('91'), 10, 1500, 6,   null),
  (pg_temp.u('d2'), pg_temp.u('92'), 4, 2500, null, null),
  (pg_temp.u('d2'), pg_temp.u('91'), 3, 1500, null, now()),
  (pg_temp.u('d3'), pg_temp.u('93'), 25, 200, null, null),
  (pg_temp.u('d4'), pg_temp.u('91'), 2, 1500, null, null);

-- Los pagos de b1: validados 12000 + 9000; no pagan: por validar (5000), rechazado (3000), validado dado de baja (1000).
insert into public.deposito (colportor_id, monto, fecha, destino, concepto, campania_id, validado_en, deleted_at) values
  (pg_temp.u('b1'), 12000, '2026-10-10 12:00:00+00', 'RETIRO_COORDINADOR', 'CASA_EDITORA', null, '2026-10-11 12:00:00+00', null),
  (pg_temp.u('b1'), 9000,  '2026-10-17 12:00:00+00', 'RETIRO_COORDINADOR', 'CASA_EDITORA', null, '2026-10-18 12:00:00+00', null),
  (pg_temp.u('b1'), 5000,  '2026-10-21 12:00:00+00', 'RETIRO_COORDINADOR', 'CASA_EDITORA', null, null, null),
  (pg_temp.u('b1'), 1000,  '2026-10-24 12:00:00+00', 'RETIRO_COORDINADOR', 'CASA_EDITORA', null, '2026-10-25 12:00:00+00', now());
insert into public.deposito (colportor_id, monto, fecha, destino, concepto, rechazado_en, rechazado_por, motivo_rechazo) values
  (pg_temp.u('b1'), 3000, '2026-10-20 12:00:00+00', 'RETIRO_COORDINADOR', 'CASA_EDITORA', '2026-10-21 08:00:00+00', pg_temp.u('c1'), 'No llegó el efectivo');
-- Y una tarjeta validada (2000), una pendiente y una rechazada que no pagan.
insert into public.ticket (id, usuario_id, tipo, monto, fecha, estado, motivo_rechazo) values
  (pg_temp.u('71'), pg_temp.u('b1'), 'COBRO_TARJETA', 2000, '2026-10-12 12:00:00+00', 'VALIDADO', null),
  (pg_temp.u('72'), pg_temp.u('b1'), 'COBRO_TARJETA', 7000, '2026-10-13 12:00:00+00', 'PENDIENTE', null),
  (pg_temp.u('73'), pg_temp.u('b1'), 'COBRO_TARJETA', 3000, '2026-10-13 13:00:00+00', 'RECHAZADO', 'Ticket ilegible');

-- b2: un pedido de 8000 y un depósito validado de 2000 (para probar que lo de b1 no le llega).
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, monto_autorizado, origen, fecha_pedido)
values (pg_temp.u('b2'), pg_temp.u('b2'), 'AUTORIZADO', 8000, 8000, 'COLPORTOR', '2026-10-05 10:00:00+00');
insert into public.deposito (colportor_id, monto, fecha, destino, concepto, validado_en) values
  (pg_temp.u('b2'), 2000, '2026-10-12 12:00:00+00', 'RETIRO_COORDINADOR', 'CASA_EDITORA', '2026-10-13 12:00:00+00');

-- b3: pedido de 4000 con 4500 validados (pagó de más: no se lista; la cuenta lo dice a favor).
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, monto_autorizado, origen, fecha_pedido)
values (pg_temp.u('b3'), pg_temp.u('b3'), 'RECIBIDO', 4000, 4000, 'COLPORTOR', '2026-10-05 10:00:00+00');
insert into public.deposito (colportor_id, monto, fecha, destino, concepto, validado_en) values
  (pg_temp.u('b3'), 4500, '2026-10-12 12:00:00+00', 'RETIRO_COORDINADOR', 'CASA_EDITORA', '2026-10-13 12:00:00+00');

-- Las cuentas, al final (los depósitos validados pueden haberlas tocado). b1 debe 15000 aunque la suma de sus saldos
-- dé otra cosa (una transferencia movió la deuda); b4 tiene la cuenta dada de baja.
insert into public.cuenta_colportor (usuario_id, deuda_total) values
  (pg_temp.u('b1'), 15000), (pg_temp.u('b3'), -500)
on conflict (usuario_id) do update set deuda_total = excluded.deuda_total, deleted_at = null;
insert into public.cuenta_colportor (usuario_id, deuda_total, deleted_at) values (pg_temp.u('b4'), 777, now())
on conflict (usuario_id) do update set deuda_total = excluded.deuda_total, deleted_at = excluded.deleted_at;
-- El historial de b1: hace 10 días debía 9000, hace 3 días pasó a 15000 (la de hace 7 días exactos es 9000).
update public.cuenta_deuda_historial set desde = now() - interval '3 days', deuda = 15000
 where usuario_id = pg_temp.u('b1');
insert into public.cuenta_deuda_historial (usuario_id, deuda, desde) values (pg_temp.u('b1'), 9000, now() - interval '10 days');

-- ---------------------------------------------------------------------------
-- 2. El pull: cada persona baja solo lo suyo
-- ---------------------------------------------------------------------------
create temp table p_b1 as select pg_temp.pull_de('b1') as d;
select is((select count(*)::int from p_b1, pg_temp.filas(d, 'cuenta_colportor') e), 1, 'Ana (b1) baja su cuenta, una sola') ;
select is((select (e ->> 'deuda_total')::bigint from p_b1, pg_temp.filas(d, 'cuenta_colportor') e), 15000::bigint,
          'con su deuda real (15000)');
select ok((select bool_and((e ->> 'usuario_id') = pg_temp.u('b1')::text and not (e ? 'xmin_w'))
             from p_b1, pg_temp.filas(d, 'cuenta_colportor') e),
          'es suya y no lleva la maquinaria del delta');
select is((select count(*)::int from p_b1, pg_temp.filas(d, 'cuenta_deuda_historial') e), 2, 'baja sus dos registros de historial');
select ok((select bool_and((e ->> 'usuario_id') = pg_temp.u('b1')::text) from p_b1, pg_temp.filas(d, 'cuenta_deuda_historial') e),
          'del historial, todos suyos');

create temp table p_b2 as select pg_temp.pull_de('b2') as d;
select is((select count(*)::int from p_b2, pg_temp.filas(d, 'cuenta_colportor') e), 0, 'b2 no tiene cuenta y no baja la de nadie');
select is((select count(*)::int from p_b2, pg_temp.filas(d, 'cuenta_deuda_historial') e), 0, 'ni historial de otra persona');

-- El coordinador y el ADMIN: la RLS (0067) deja leer la cuenta de las colportoras de sus campañas / de todas, pero su
-- teléfono baja solo la propia (columna_duenio): ninguna.
create temp table p_ad as select pg_temp.pull_de('ad') as d;
select is((select count(*)::int from p_ad, pg_temp.filas(d, 'cuenta_colportor') e), 0, 'el ADMIN no baja la cuenta de nadie');
create temp table p_c1 as select pg_temp.pull_de('c1') as d;
select is((select count(*)::int from p_c1, pg_temp.filas(d, 'cuenta_colportor') e), 0, 'ni el coordinador');

-- ---------------------------------------------------------------------------
-- 3. Los casos de #235 calculados con lo que baja: igual que la RPC
-- ---------------------------------------------------------------------------
select is(pg_temp.en_el_telefono((select d from p_b1)), pg_temp.por_rpc('b1'),
          'b1: el reparto del teléfono (con las filas del pull) es IGUAL al de la RPC');
select is(pg_temp.en_el_telefono((select d from p_b1)),
          '15000|9000|9000|21000|2000|a2:10000/9000/1000[], a3:5000/0/5000[], a4:3000/0/3000[]',
          'b1: 23000 pagados (21000 en depósitos + 2000 de tarjeta): a1 (14000) entero, a2 a medias, a3 y a4 sin pagar; deuda real 15000; hace 7 días, 9000');
select is((select count(*)::int from p_b1, pg_temp.filas(d, 'pedido_casa_editora') e), 9,
          'bajan los nueve pedidos (también los que no cuentan: el teléfono decide con el estado)');

create temp table p_b3 as select pg_temp.pull_de('b3') as d;
select is(pg_temp.en_el_telefono((select d from p_b3)), '-500|n|0|4500|0|-', 'b3: pagó de más, la deuda a favor sale negativa y no se lista el pedido');
select is(pg_temp.en_el_telefono((select d from p_b3)), pg_temp.por_rpc('b3'), 'b3: igual a la RPC');

create temp table p_b4 as select pg_temp.pull_de('b4') as d;
select is(pg_temp.en_el_telefono((select d from p_b4)), '0|n|0|0|0|-', 'b4: una cuenta dada de baja no debe nada');
select is(pg_temp.en_el_telefono((select d from p_b4)), pg_temp.por_rpc('b4'), 'b4: igual a la RPC');

select is(pg_temp.en_el_telefono((select d from p_b2)), pg_temp.por_rpc('b2'), 'b2: igual a la RPC (sin cuenta, pedido pagado con su depósito)');
select is(pg_temp.en_el_telefono((select d from p_b2)), '0|n|6000|2000|0|b2:8000/2000/6000[]', 'b2: sin cuenta el total es 0 y el saldo del pedido, 6000');

create temp table p_b7 as select pg_temp.pull_de('b7') as d;
select is(pg_temp.en_el_telefono((select d from p_b7)), pg_temp.por_rpc('b7'), 'b7: las líneas (cantidad autorizada, sin las de cero ni las dadas de baja, por nombre) son iguales a las de la RPC');
select is(pg_temp.en_el_telefono((select d from p_b7)),
          '0|n|32000|0|0|d1:14000/0/14000[Libro Dos 179 x2, Libro Uno 179 x6], d2:10000/0/10000[Libro Dos 179 x4], d3:5000/0/5000[Revista Uno 179 x25], d4:3000/0/3000[Libro Uno 179 x2]',
          'b7: sin pagos, los cuatro pedidos enteros con sus líneas');

-- Más pagos validados por el servidor: el reparto sigue igual a la RPC (lo que sobra no está en ningún pedido).
select pg_temp.como_servidor();
insert into public.deposito (colportor_id, monto, fecha, destino, concepto, validado_en) values
  (pg_temp.u('b1'), 4000, '2026-10-26 12:00:00+00', 'RETIRO_COORDINADOR', 'CASA_EDITORA', '2026-10-27 12:00:00+00');
update public.deposito set validado_en = '2026-10-28 12:00:00+00'
 where colportor_id = pg_temp.u('b1') and monto = 5000 and concepto = 'CASA_EDITORA';
create temp table p_b1b as select pg_temp.pull_de('b1') as d;
select is(pg_temp.en_el_telefono((select d from p_b1b)), pg_temp.por_rpc('b1'),
          'b1, con otro depósito y el que estaba por validar ya validado: sigue igual a la RPC');
select is(pg_temp.en_el_telefono((select d from p_b1b)), '15000|9000|0|30000|2000|-',
          'b1: 32000 pagados cubren todo (14000 + 10000 + 5000 + 3000): no se lista ningún pedido');
select pg_temp.como_servidor();
insert into public.deposito (colportor_id, monto, fecha, destino, concepto, validado_en) values
  (pg_temp.u('b1'), 6000, '2026-10-29 12:00:00+00', 'RETIRO_COORDINADOR', 'CASA_EDITORA', '2026-10-30 12:00:00+00');
select is(pg_temp.en_el_telefono(pg_temp.pull_de('b1')), pg_temp.por_rpc('b1'), 'b1 pagó de más: sigue igual a la RPC');

-- ---------------------------------------------------------------------------
-- 4. El delta: cuando el servidor mueve la deuda baja la fila nueva, solo a su dueña
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
update public.cuenta_colportor set deuda_total = 12000 where usuario_id = pg_temp.u('b1');
create temp table p_b1c as select pg_temp.delta_de('b1', (select d -> 'watermark' from p_b1)) as d;
select is((select (e ->> 'deuda_total')::bigint from p_b1c, pg_temp.filas(d, 'cuenta_colportor') e), 12000::bigint,
          'la deuda nueva (12000) baja por el delta, en la cuenta');
select is((select count(*)::int from p_b1c, pg_temp.filas(d, 'cuenta_deuda_historial') e where (e ->> 'deuda')::bigint = 12000), 1,
          'y el historial suma el registro del cambio');
select is((select count(*)::int from pg_temp.filas(pg_temp.delta_de('b2', (select d -> 'watermark' from p_b2)), 'cuenta_colportor')),
          0, 'y a b2 no le llega nada');

-- ---------------------------------------------------------------------------
-- 5. Solo bajada: el teléfono no escribe la cuenta ni el historial
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(
  sync.push(jsonb_build_array(jsonb_build_object(
    'client_op_id', '01920000-0000-7000-8000-000000179b01', 'entity', 'cuenta_colportor', 'op', 'update',
    'sync_version', 1, 'payload', jsonb_build_object('id', (select id from public.cuenta_colportor where usuario_id = pg_temp.u('b1')),
                                                    'deuda_total', 0))))
    #>> '{results,0,code}',
  'ENTIDAD_DE_SOLO_LECTURA', 'subir una deuda en cero se rechaza (la réplica es de solo lectura)');
select pg_temp.como_servidor();
select is((select deuda_total from public.cuenta_colportor where usuario_id = pg_temp.u('b1')), 12000::bigint,
          'y la deuda sigue siendo la del servidor');

-- ---------------------------------------------------------------------------
-- Limpieza
-- ---------------------------------------------------------------------------
drop table p_b1, p_b2, p_b3, p_b4, p_b7, p_ad, p_c1, p_b1b, p_b1c;
select pg_temp.limpiar();
select is((select count(*)::int from public.cuenta_colportor
            where usuario_id in (pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('b3'), pg_temp.u('b4'))), 0,
          'limpieza: no queda nada de la prueba');

select * from finish();
