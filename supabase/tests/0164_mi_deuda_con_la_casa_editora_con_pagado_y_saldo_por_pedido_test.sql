-- pgTAP · migración 0164 (backend-supabase#235, BACK-HU-CTA-002; decisiones de Cristian del 03/11 «Pagado ped.» y
-- «Leer deuda»): el RPC `mi_deuda_con_la_casa_editora()`.
--   1. La forma: existe, devuelve jsonb, es DEFINER y estable; EXECUTE solo para `authenticated`; las claves de la
--      respuesta y las de cada pedido son exactamente las del contrato (ni clientes ni cobros).
--   2. Sin sesión: 42501 con un aviso que dice qué hacer; `anon` no la ejecuta.
--   3. La cuenta: sin pedidos ni cuenta todo vale 0; los depósitos VALIDADOS a la casa editora pagan primero el pedido más
--      viejo (los por validar, los retiros rechazados, los de alquiler y los dados de baja no pagan); solo cuentan los
--      pedidos AUTORIZADO, DESPACHADO y RECIBIDO vivos, con `monto_autorizado` o `monto_total`; el empate de fecha se
--      desempata por número; un pedido pagado justo o de más no se lista; lo que sobra no aparece en ningún pedido.
--   4. El total es el real (`cuenta_colportor.deuda_total`) y puede no coincidir con la suma de saldos: se devuelven
--      las dos; una cuenta de baja no debe nada; una deuda a favor sale negativa.
--   5. Las líneas: las vivas, con la cantidad autorizada si se redujo, sin las que quedaron en cero, por nombre.
--   6. Cada colportora ve solo lo suyo; un coordinador y un ADMIN ven su propia cuenta; la lectura es repetible y no
--      cambia nada.
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
create or replace function pg_temp.actuar_sin_jwt() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
  perform set_config('role', 'authenticated', true);
end $$;
create or replace function pg_temp.actuar_como_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', 'anon', true);
  perform set_config('role', 'anon', true);
end $$;
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000161' || p)::uuid;
$$;
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate || ' ' || sqlerrm;
end $$;
-- La respuesta de la colportora p (como ella), vuelta al servidor.
create or replace function pg_temp.mi(p text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform pg_temp.actuar_como(pg_temp.u(p));
  r := public.mi_deuda_con_la_casa_editora();
  perform pg_temp.actuar_como_servidor();
  return r;
end $$;
-- «total|suma de saldos|depósitos validados».
create or replace function pg_temp.cifras(p text) returns text language sql as $$
  select format('%s|%s|%s', j ->> 'deuda_total', j ->> 'suma_de_saldos', j ->> 'depositos_validados')
    from (select pg_temp.mi(p) j) x;
$$;
-- Los pedidos en una línea: «id:monto/pagado/saldo/estado», del más viejo al más nuevo.
create or replace function pg_temp.pedidos(p text) returns text language sql as $$
  select coalesce(string_agg(format('%s:%s/%s/%s/%s', right(e ->> 'pedido_id', 2), e ->> 'monto', e ->> 'pagado',
                                    e ->> 'saldo', e ->> 'estado'), ', ' order by ord), '-')
    from jsonb_array_elements(pg_temp.mi(p) -> 'pedidos') with ordinality t(e, ord);
$$;
-- Las líneas de un pedido: «Nombre xN, …» (en el orden en que vienen).
create or replace function pg_temp.lineas(p text, p_ped text) returns text language sql as $$
  select coalesce(string_agg(l ->> 'nombre' || ' x' || (l ->> 'cantidad'), ', ' order by ord), '-')
    from jsonb_array_elements(pg_temp.mi(p) -> 'pedidos') t(e),
         jsonb_array_elements(e -> 'lineas') with ordinality x(l, ord)
   where right(e ->> 'pedido_id', 2) = p_ped;
$$;

-- --- fixtures ------------------------------------------------------------------
-- Colportoras: b1 (la del reparto), b2 (otra, sin cuenta), b3 (a favor), b4 (cuenta dada de baja), b5 (sin nada),
-- b6 (paga justo un pedido), b7 (los pedidos con líneas, sin pagar nada). c1 coordinador. ad ADMIN.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'deuda155-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','b3','b4','b5','b6','b7','c1','ad']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'), ('b4','COLPORTOR'), ('b5','COLPORTOR'),
               ('b6','COLPORTOR'), ('b7','COLPORTOR'), ('c1','COORDINADOR'), ('ad','ADMIN')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'e1 deuda155', 'VERANO', public.hoy_montevideo() - 40, public.hoy_montevideo() + 30, pg_temp.u('c1'));
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), now() - interval '40 days');

insert into public.producto (id, nombre, tipo, precio_base_compra) values
  (pg_temp.u('91'), 'Libro Uno',   'LIBRO',   1500),
  (pg_temp.u('92'), 'Libro Dos',   'LIBRO',   2500),
  (pg_temp.u('93'), 'Revista Uno', 'REVISTA', 200);

-- Los pedidos de b1, uno por sentencia para que el número siga el orden en que se escriben.
--   pa AUTORIZADO 02/10, pedido 26000 y autorizado 14000 (el coordinador lo bajó)
--   pb DESPACHADO 15/10, 10000   pc AUTORIZADO 15/10 (misma fecha, número más alto), del coordinador: sin monto
--   autorizado, vale el total 5000   pd RECIBIDO 20/10, 3000
--   los que NO cuentan: por autorizar 7000, rechazado 3000, cancelado 1000, borrador 2000 y uno autorizado dado de baja 9000
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, monto_autorizado, origen, fecha_pedido)
values (pg_temp.u('a1'), pg_temp.u('b1'), 'AUTORIZADO', 26000, 14000, 'COLPORTOR', '2026-10-02 10:00:00+00');
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, monto_autorizado, origen, fecha_pedido)
values (pg_temp.u('a2'), pg_temp.u('b1'), 'DESPACHADO', 10000, 10000, 'COLPORTOR', '2026-10-15 10:00:00+00');
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, monto_autorizado, origen, fecha_pedido)
values (pg_temp.u('a3'), pg_temp.u('b1'), 'AUTORIZADO', 5000, null, 'COORDINADOR', '2026-10-15 10:00:00+00');
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, monto_autorizado, origen, fecha_pedido)
values (pg_temp.u('a4'), pg_temp.u('b1'), 'RECIBIDO', 3000, 3000, 'COLPORTOR', '2026-10-20 10:00:00+00');
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, origen, fecha_pedido, motivo_rechazo, deleted_at)
values (pg_temp.u('a5'), pg_temp.u('b1'), 'PENDIENTE_AUTORIZACION', 7000, 'COLPORTOR', '2026-10-01 10:00:00+00', null, null),
       (pg_temp.u('a6'), pg_temp.u('b1'), 'RECHAZADO',               3000, 'COLPORTOR', '2026-10-01 11:00:00+00', 'Sin cupo', null),
       (pg_temp.u('a7'), pg_temp.u('b1'), 'CANCELADO',               1000, 'COLPORTOR', '2026-10-01 12:00:00+00', null, null),
       (pg_temp.u('a8'), pg_temp.u('b1'), 'BORRADOR',                2000, 'COORDINADOR', '2026-10-01 13:00:00+00', null, null);
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, monto_autorizado, origen, fecha_pedido, deleted_at)
values (pg_temp.u('a9'), pg_temp.u('b1'), 'AUTORIZADO', 9000, 9000, 'COLPORTOR', '2026-10-01 14:00:00+00', now());

-- b7: los mismos cuatro pedidos que cuentan, con sus líneas y sin pagar nada. d1 baja Libro Uno de 10 a 6 y Libro Dos de
-- 4 a 2, y la Revista de 5 a 0 (sale de la deuda); d2 tiene Libro Dos y una línea de Libro Uno dada de baja; d3, la
-- Revista; d4, Libro Uno. Las líneas se escriben en desorden para probar el orden por nombre. Los pedidos de b1 no tienen líneas.
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

-- Los depósitos de b1 (retiros del coordinador: no piden ticket). Pagan: 12000 + 9000 = 21000 validados a la casa
-- editora. No pagan: uno por validar (5000), un retiro rechazado (3000), uno de alquiler validado (7000) y uno validado
-- dado de baja (1000).
insert into public.deposito (colportor_id, monto, fecha, destino, concepto, campania_id, validado_en, deleted_at) values
  (pg_temp.u('b1'), 12000, '2026-10-10 12:00:00+00', 'RETIRO_COORDINADOR', 'CASA_EDITORA', null, '2026-10-11 12:00:00+00', null),
  (pg_temp.u('b1'), 9000,  '2026-10-17 12:00:00+00', 'RETIRO_COORDINADOR', 'CASA_EDITORA', null, '2026-10-18 12:00:00+00', null),
  (pg_temp.u('b1'), 5000,  '2026-10-21 12:00:00+00', 'RETIRO_COORDINADOR', 'CASA_EDITORA', null, null, null),
  (pg_temp.u('b1'), 7000,  '2026-10-22 12:00:00+00', 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e1'), '2026-10-23 12:00:00+00', null),
  (pg_temp.u('b1'), 1000,  '2026-10-24 12:00:00+00', 'RETIRO_COORDINADOR', 'CASA_EDITORA', null, '2026-10-25 12:00:00+00', now());
insert into public.deposito (colportor_id, monto, fecha, destino, concepto, rechazado_en, rechazado_por, motivo_rechazo) values
  (pg_temp.u('b1'), 3000, '2026-10-20 12:00:00+00', 'RETIRO_COORDINADOR', 'CASA_EDITORA', '2026-10-21 08:00:00+00', pg_temp.u('c1'), 'No llegó el efectivo');

-- b2: un pedido de 8000 y un depósito validado de 2000, sin cuenta.
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, monto_autorizado, origen, fecha_pedido)
values (pg_temp.u('b2'), pg_temp.u('b2'), 'AUTORIZADO', 8000, 8000, 'COLPORTOR', '2026-10-05 10:00:00+00');
insert into public.deposito (colportor_id, monto, fecha, destino, concepto, validado_en) values
  (pg_temp.u('b2'), 2000, '2026-10-12 12:00:00+00', 'RETIRO_COORDINADOR', 'CASA_EDITORA', '2026-10-13 12:00:00+00');

-- b3: pedido de 4000 con 4500 validados (pagó de más): no se lista; la cuenta lo dice a favor (-500).
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, monto_autorizado, origen, fecha_pedido)
values (pg_temp.u('b3'), pg_temp.u('b3'), 'RECIBIDO', 4000, 4000, 'COLPORTOR', '2026-10-05 10:00:00+00');
insert into public.deposito (colportor_id, monto, fecha, destino, concepto, validado_en) values
  (pg_temp.u('b3'), 4500, '2026-10-12 12:00:00+00', 'RETIRO_COORDINADOR', 'CASA_EDITORA', '2026-10-13 12:00:00+00');

-- b6: pedido de 5000 y 5000 validados justo.
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, monto_autorizado, origen, fecha_pedido)
values (pg_temp.u('b6'), pg_temp.u('b6'), 'DESPACHADO', 5000, 5000, 'COLPORTOR', '2026-10-05 10:00:00+00');
insert into public.deposito (colportor_id, monto, fecha, destino, concepto, validado_en) values
  (pg_temp.u('b6'), 5000, '2026-10-12 12:00:00+00', 'RETIRO_COORDINADOR', 'CASA_EDITORA', '2026-10-13 12:00:00+00');

-- La cuenta de cada una, al final (los depósitos validados de arriba pueden haberla tocado). b1 debe 15000 aunque la
-- suma de sus saldos dé otra cosa (una transferencia movió la deuda); b4 tiene la cuenta dada de baja.
insert into public.cuenta_colportor (usuario_id, deuda_total) values
  (pg_temp.u('b1'), 15000), (pg_temp.u('b3'), -500)
on conflict (usuario_id) do update set deuda_total = excluded.deuda_total, deleted_at = null;
insert into public.cuenta_colportor (usuario_id, deuda_total, deleted_at) values (pg_temp.u('b4'), 777, now())
on conflict (usuario_id) do update set deuda_total = excluded.deuda_total, deleted_at = excluded.deleted_at;
select pg_temp.actuar_como_servidor();

-- --- 1. la forma ---------------------------------------------------------------
select has_function('public', 'mi_deuda_con_la_casa_editora', array[]::text[], 'la función existe, sin parámetros');
select function_returns('public', 'mi_deuda_con_la_casa_editora', array[]::text[], 'jsonb', 'devuelve jsonb');
select is((select prosecdef from pg_proc where oid = 'public.mi_deuda_con_la_casa_editora()'::regprocedure), true,
          'es SECURITY DEFINER');
select is((select provolatile from pg_proc where oid = 'public.mi_deuda_con_la_casa_editora()'::regprocedure), 's',
          'y estable: solo lee');
select is((select has_function_privilege(r, 'public.mi_deuda_con_la_casa_editora()', 'execute')), r = 'authenticated',
          format('EXECUTE de %s', r))
  from unnest(array['anon', 'authenticated', 'service_role']) r;
select is((select array_agg(k order by k collate "C") from jsonb_object_keys(pg_temp.mi('b1')) k),
          array['depositos_validados', 'deuda_hace_7_dias', 'deuda_total', 'pedidos', 'suma_de_saldos', 'tarjetas_validadas'],
          'la respuesta tiene exactamente las seis claves del contrato (0165 suma tarjetas_validadas, 0168 deuda_hace_7_dias)');
select is((select array_agg(k order by k collate "C") from jsonb_object_keys(pg_temp.mi('b1') -> 'pedidos' -> 0) k),
          array['estado', 'fecha_pedido', 'lineas', 'monto', 'numero', 'pagado', 'pedido_id', 'saldo'],
          'cada pedido tiene exactamente sus ocho claves (ni clientes ni cobros)');
select is((select array_agg(k order by k collate "C") from jsonb_object_keys(pg_temp.mi('b7') -> 'pedidos' -> 0 -> 'lineas' -> 0) k),
          array['cantidad', 'nombre', 'producto_id'], 'y cada línea, sus tres');

-- --- 2. sin sesión -------------------------------------------------------------
select pg_temp.actuar_sin_jwt();
select is(pg_temp.error_de('select public.mi_deuda_con_la_casa_editora()'),
          '42501 Iniciá sesión para ver tu deuda con la casa editora.', 'sin JWT: 42501 y dice qué hacer');
select pg_temp.actuar_como_anon();
select is(left(pg_temp.error_de('select public.mi_deuda_con_la_casa_editora()'), 5), '42501', 'anon: sin permiso');
select pg_temp.actuar_como_servidor();

-- --- 3. el reparto: los depósitos validados pagan primero el pedido más viejo ----
-- b1: pa 14000 (pagado 14000, saldo 0: no se lista), pb 10000 (pagado 7000, saldo 3000), pc 5000 (pagado 0, saldo 5000;
-- misma fecha que pb, número más alto) y pd 3000 (saldo 3000). Suma de saldos 11000; lo pagado, 21000.
select is(pg_temp.pedidos('b1'),
          'a2:10000/7000/3000/DESPACHADO, a3:5000/0/5000/AUTORIZADO, a4:3000/0/3000/RECIBIDO',
          'b1: el pedido más viejo se paga entero (y no se lista), el siguiente a medias, y el empate de fecha va por número');
select is(pg_temp.cifras('b1'), '15000|11000|21000',
          'b1: el total es el real (15000) y la suma de saldos (11000) puede no coincidir: se devuelven las dos y lo validado');
select is((select jsonb_array_length(pg_temp.mi('b1') -> 'pedidos')), 3,
          'no cuentan: por autorizar, rechazado, cancelado, borrador ni el dado de baja; ni se lista el pagado');
select is((select e ->> 'monto' from jsonb_array_elements(pg_temp.mi('b1') -> 'pedidos') e where right(e ->> 'pedido_id', 2) = 'a3'),
          '5000', 'un pedido sin monto autorizado vale su total');
select is(pg_temp.pedidos('b1'), pg_temp.pedidos('b1'), 'leerlo dos veces da lo mismo');

-- Un depósito más, validado ahora: termina de pagar pb y empieza pc.
insert into public.deposito (colportor_id, monto, fecha, destino, concepto, validado_en) values
  (pg_temp.u('b1'), 4000, '2026-10-26 12:00:00+00', 'RETIRO_COORDINADOR', 'CASA_EDITORA', '2026-10-27 12:00:00+00');
select is(pg_temp.pedidos('b1'), 'a3:5000/1000/4000/AUTORIZADO, a4:3000/0/3000/RECIBIDO',
          'otro depósito validado (4000, 25000 en total): pb queda pagado y pc a medias');
-- El que estaba por validar se valida: termina pc y empieza pd.
update public.deposito set validado_en = '2026-10-28 12:00:00+00'
 where colportor_id = pg_temp.u('b1') and monto = 5000 and concepto = 'CASA_EDITORA';
select is(pg_temp.pedidos('b1'), 'a4:3000/1000/2000/RECIBIDO',
          'al validar el que estaba por validar (5000): pc queda pagado y pd a medias');
-- Lo rechazado, lo de alquiler y lo dado de baja nunca pagaron: lo validado es 12000 + 9000 + 4000 + 5000.
select is(pg_temp.cifras('b1'), '15000|2000|30000', 'b1: lo validado ahora es 30000 y quedan 2000 de saldo');
-- Pagado de más: lo que sobra no aparece en ningún pedido.
insert into public.deposito (colportor_id, monto, fecha, destino, concepto, validado_en) values
  (pg_temp.u('b1'), 6000, '2026-10-29 12:00:00+00', 'RETIRO_COORDINADOR', 'CASA_EDITORA', '2026-10-30 12:00:00+00');
select is(pg_temp.pedidos('b1'), '-', 'con todo pagado no se lista ningún pedido');
select is(pg_temp.cifras('b1'), '15000|0|36000',
          'y la suma de saldos es 0 (lo que sobra no está en ningún pedido; el total real sigue siendo el de la cuenta)');

-- --- 4. otras colportoras: solo lo suyo ----------------------------------------
select is(pg_temp.pedidos('b2'), 'b2:8000/2000/6000/AUTORIZADO', 'b2: solo su pedido, pagado con su depósito (no el de b1)');
select is(pg_temp.cifras('b2'), '0|6000|2000', 'b2: sin cuenta el total es 0 y la suma de saldos dice 6000: se ven las dos');
select is(pg_temp.pedidos('b3'), '-', 'b3: pagó de más: no se lista el pedido');
select is(pg_temp.cifras('b3'), '-500|0|4500', 'b3: la deuda a favor sale negativa');
select is(pg_temp.pedidos('b6'), '-', 'b6: 5000 validados pagan justo un pedido de 5000: saldo 0, no se lista');
select is(pg_temp.cifras('b6'), '0|0|5000', 'b6: todo en cero');
select is(pg_temp.cifras('b4'), '0|0|0', 'b4: una cuenta dada de baja no debe nada');
select is(pg_temp.cifras('b5'), '0|0|0', 'b5: sin cuenta ni pedidos todo vale 0');
select is(pg_temp.pedidos('b5'), '-', 'b5: la lista de pedidos viene vacía');
select is(pg_temp.mi('b5') -> 'pedidos', '[]'::jsonb, 'b5: es una lista vacía, no null');
select is(pg_temp.cifras('c1'), '0|0|0', 'el coordinador ve su propia cuenta (vacía), no la de sus colportoras');
select is(pg_temp.cifras('ad'), '0|0|0', 'el ADMIN también ve la suya');

-- --- 5. las líneas -------------------------------------------------------------
select is(pg_temp.pedidos('b7'),
          'd1:14000/0/14000/AUTORIZADO, d2:10000/0/10000/DESPACHADO, d3:5000/0/5000/AUTORIZADO, d4:3000/0/3000/RECIBIDO',
          'b7: sin pagos todos los pedidos que cuentan se listan enteros, con su monto autorizado');
select is(pg_temp.lineas('b7', 'd1'), 'Libro Dos x2, Libro Uno x6',
          'd1: cantidad autorizada (no la pedida), sin la línea que quedó en cero, ordenadas por nombre');
select is(pg_temp.lineas('b7', 'd2'), 'Libro Dos x4', 'd2: la línea dada de baja no cuenta');
select is(pg_temp.lineas('b7', 'd3'), 'Revista Uno x25', 'd3: la revista');
select is(pg_temp.lineas('b7', 'd4'), 'Libro Uno x2', 'd4: la cantidad pedida si no se redujo');
select is(pg_temp.lineas('b2', 'b2'), '-', 'un pedido sin líneas (todavía no bajaron) sale sin líneas');
select is((select e -> 'lineas' from jsonb_array_elements(pg_temp.mi('b2') -> 'pedidos') e limit 1), '[]'::jsonb,
          'y es una lista vacía, no null');
select is(pg_temp.cifras('b7'), '0|32000|0', 'b7: sin cuenta el total es 0 y la suma de saldos es 32000');

select * from finish();
rollback;
