-- pgTAP · migración 0165 (backend-supabase#243, casilla «Tarjeta ped.»; decisión de Cristian del 04/11, «Sí, como un
-- depósito»): en `mi_deuda_con_la_casa_editora()` los cobros con tarjeta validados pagan los pedidos igual que los depósitos.
--   1. La forma: la respuesta suma `tarjetas_validadas`; `depositos_validados` sigue siendo solo de depósitos.
--   2. Depósito + tarjeta reparten por antigüedad (el más viejo primero) y la suma de saldos da el total de la cuenta.
--   3. Solo paga el ticket de tarjeta VALIDADO y vivo de la propia colportora: no el pendiente, el rechazado, el de
--      otro tipo, el dado de baja ni el de otra persona; al validarse, empieza a pagar.
--   4. Solo tarjeta (sin depósitos) y sin pedidos.
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
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000165' || p)::uuid;
$$;
-- La respuesta de la colportora p (como ella), vuelta al servidor.
create or replace function pg_temp.mi(p text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform pg_temp.actuar_como(pg_temp.u(p));
  r := public.mi_deuda_con_la_casa_editora();
  perform pg_temp.actuar_como_servidor();
  return r;
end $$;
-- «total|suma de saldos|depósitos validados|tarjetas validadas».
create or replace function pg_temp.cifras(p text) returns text language sql as $$
  select format('%s|%s|%s|%s', j ->> 'deuda_total', j ->> 'suma_de_saldos', j ->> 'depositos_validados',
                j ->> 'tarjetas_validadas')
    from (select pg_temp.mi(p) j) x;
$$;
-- Los pedidos en una línea: «id:monto/pagado/saldo», del más viejo al más nuevo.
create or replace function pg_temp.pedidos(p text) returns text language sql as $$
  select coalesce(string_agg(format('%s:%s/%s/%s', right(e ->> 'pedido_id', 2), e ->> 'monto', e ->> 'pagado',
                                    e ->> 'saldo'), ', ' order by ord), '-')
    from jsonb_array_elements(pg_temp.mi(p) -> 'pedidos') with ordinality t(e, ord);
$$;

-- --- fixtures ------------------------------------------------------------------
-- b1: depósito y tarjeta; b2: solo tarjeta; b3: tarjeta sin pedidos; b4: la dueña de un ticket que no paga a b1.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'tarjeta165-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','b3','b4']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'), ('b4','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

-- Los pedidos de b1: a1 20000 (02/10), a2 10000 (15/10), a3 5000 (20/10): 35000 en total.
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, monto_autorizado, origen, fecha_pedido)
values (pg_temp.u('a1'), pg_temp.u('b1'), 'AUTORIZADO', 20000, 20000, 'COLPORTOR', '2026-10-02 10:00:00+00');
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, monto_autorizado, origen, fecha_pedido)
values (pg_temp.u('a2'), pg_temp.u('b1'), 'DESPACHADO', 10000, 10000, 'COLPORTOR', '2026-10-15 10:00:00+00');
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, monto_autorizado, origen, fecha_pedido)
values (pg_temp.u('a3'), pg_temp.u('b1'), 'RECIBIDO', 5000, 5000, 'COLPORTOR', '2026-10-20 10:00:00+00');
-- b2: un pedido de 8000.
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, monto_autorizado, origen, fecha_pedido)
values (pg_temp.u('b2'), pg_temp.u('b2'), 'AUTORIZADO', 8000, 8000, 'COLPORTOR', '2026-10-05 10:00:00+00');

-- Un depósito validado de b1 (12000) y un ticket de tarjeta validado (10000): pagan 22000.
insert into public.deposito (colportor_id, monto, fecha, destino, concepto, validado_en) values
  (pg_temp.u('b1'), 12000, '2026-10-10 12:00:00+00', 'RETIRO_COORDINADOR', 'CASA_EDITORA', '2026-10-11 12:00:00+00');
insert into public.ticket (id, usuario_id, tipo, monto, fecha, estado) values
  (pg_temp.u('11'), pg_temp.u('b1'), 'COBRO_TARJETA', 10000, '2026-10-12 12:00:00+00', 'VALIDADO');
-- Los que NO pagan: una tarjeta pendiente (7000), una rechazada (3000), un ticket «otro» validado (999), una tarjeta
-- validada dada de baja (2000) y una tarjeta validada de otra colportora (5000).
insert into public.ticket (id, usuario_id, tipo, monto, fecha, estado, motivo_rechazo) values
  (pg_temp.u('12'), pg_temp.u('b1'), 'COBRO_TARJETA', 7000, '2026-10-13 12:00:00+00', 'PENDIENTE', null),
  (pg_temp.u('13'), pg_temp.u('b1'), 'COBRO_TARJETA', 3000, '2026-10-13 13:00:00+00', 'RECHAZADO', 'Ticket ilegible'),
  (pg_temp.u('14'), pg_temp.u('b1'), 'OTRO',            999, '2026-10-13 14:00:00+00', 'VALIDADO', null);
insert into public.ticket (id, usuario_id, tipo, monto, fecha, estado, deleted_at) values
  (pg_temp.u('15'), pg_temp.u('b1'), 'COBRO_TARJETA', 2000, '2026-10-13 15:00:00+00', 'VALIDADO', now());
insert into public.ticket (id, usuario_id, tipo, monto, fecha, estado) values
  (pg_temp.u('16'), pg_temp.u('b4'), 'COBRO_TARJETA', 5000, '2026-10-13 16:00:00+00', 'VALIDADO');
-- La deuda de b1: 35000 de pedidos menos lo pagado (22000) = 13000.
insert into public.cuenta_colportor (usuario_id, deuda_total) values (pg_temp.u('b1'), 13000)
on conflict (usuario_id) do update set deuda_total = excluded.deuda_total, deleted_at = null;

-- b2: 3000 de tarjeta, sin depósitos.
insert into public.ticket (id, usuario_id, tipo, monto, fecha, estado) values
  (pg_temp.u('21'), pg_temp.u('b2'), 'COBRO_TARJETA', 3000, '2026-10-12 12:00:00+00', 'VALIDADO');
-- b3: tarjeta validada y ningún pedido.
insert into public.ticket (id, usuario_id, tipo, monto, fecha, estado) values
  (pg_temp.u('31'), pg_temp.u('b3'), 'COBRO_TARJETA', 4000, '2026-10-12 12:00:00+00', 'VALIDADO');
select pg_temp.actuar_como_servidor();

-- --- 1. la forma ---------------------------------------------------------------
select is((select array_agg(k order by k collate "C") from jsonb_object_keys(pg_temp.mi('b1')) k),
          array['depositos_validados', 'deuda_hace_7_dias', 'deuda_total', 'pedidos', 'suma_de_saldos', 'tarjetas_validadas'],
          'la respuesta trae tarjetas_validadas junto a depositos_validados');
select is(pg_temp.mi('b1') ->> 'depositos_validados', '12000', 'depositos_validados sigue siendo solo lo de los depósitos');
select is(pg_temp.mi('b1') ->> 'tarjetas_validadas', '10000', 'y tarjetas_validadas, solo lo de las tarjetas validadas');

-- --- 2. depósito + tarjeta reparten por antigüedad -------------------------------
-- 22000 pagados: a1 (20000) entero, a2 con 2000 (saldo 8000), a3 sin pagar. Los saldos suman 13000 = la deuda de la cuenta.
select is(pg_temp.pedidos('b1'), 'a2:10000/2000/8000, a3:5000/0/5000',
          'el más viejo se paga entero (no se lista), el siguiente con lo que sobra y el último nada');
select is(pg_temp.cifras('b1'), '13000|13000|12000|10000',
          'la suma de saldos da el total de la cuenta: el aviso de «algo más lo movió» ya no hace falta');
select is((select sum((e ->> 'saldo')::bigint) from jsonb_array_elements(pg_temp.mi('b1') -> 'pedidos') e),
          13000::numeric, 'los saldos de los pedidos suman 13000');

-- --- 3. solo paga la tarjeta validada, viva y propia ------------------------------
-- La pendiente (7000) se valida: 29000 pagados, a2 queda con 9000 y a3 sin pagar.
update public.ticket set estado = 'VALIDADO' where id = pg_temp.u('12');
select is(pg_temp.pedidos('b1'), 'a2:10000/9000/1000, a3:5000/0/5000', 'al validar la tarjeta pendiente, empieza a pagar');
select is(pg_temp.cifras('b1'), '13000|6000|12000|17000', 'y tarjetas_validadas sube a 17000 (la deuda de la cuenta es la que guarda la cuenta)');
-- Sin rechazada, sin «otro», sin la dada de baja y sin la ajena: la lectura es repetible.
select is(pg_temp.pedidos('b1'), pg_temp.pedidos('b1'), 'leerlo dos veces da lo mismo');
-- Otra tarjeta validada de la dueña de un ticket ajeno no cambia a b1.
select is(pg_temp.cifras('b4'), '0|0|0|5000', 'b4: su tarjeta es suya (sin pedidos no hay nada que pagar)');

-- --- 4. solo tarjeta y sin pedidos --------------------------------------------------
select is(pg_temp.pedidos('b2'), 'b2:8000/3000/5000', 'b2: la tarjeta sola paga 3000 de su pedido (no los de otros)');
select is(pg_temp.cifras('b2'), '0|5000|0|3000', 'b2: sin cuenta el total es 0 y la suma de saldos dice 5000: se ven las dos');
select is(pg_temp.pedidos('b3'), '-', 'b3: sin pedidos no se lista nada');
select is(pg_temp.cifras('b3'), '0|0|0|4000', 'b3: la tarjeta se ve en tarjetas_validadas');

select * from finish();
rollback;
