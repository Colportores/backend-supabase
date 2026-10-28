-- pgTAP · migración 0121 (backend-supabase#172, seguimiento de #134): la devolución y su anulación quedan
-- en auditoria.audit_log (ADR-002 «Efectos» 6; decisión «Audit log», 0073).
--   1. La forma: las dos funciones DEFINER sin EXECUTE para nadie y los dos triggers AFTER por fila.
--   2. El alta deja `devolucion_registrada`, con el actor, la tabla, la fila y un detalle de solo ids,
--      cantidades, centavos y la fecha; sin texto libre ni datos del cliente.
--   3. La anulación (deleted_at null -> fecha) deja `devolucion_anulada`; otra columna, una baja repetida o
--      reactivar no registran nada; la ajena no se puede anular ni deja evento.
--   4. Registrada y anulada en el mismo lote (la fila entra ya dada de baja): los dos eventos.
--   5. Por sync.push (y una devolución de 120 renglones: el detalle es de tamaño fijo y no tumba el alta ni la baja): el alta y la baja registran una vez; el reintento (duplicate), la baja repetida y lo que
--      se rechaza (invalid) no suman eventos.
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

-- Ids (prefijo 91): usuarios 91b1.., productos 9111.., ventas 9171.., devoluciones 91d1..; los client_op_id,
-- 91 y dos dígitos.
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-00000000' || '91' || p)::uuid;
$$;
create or replace function pg_temp.op(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000091' || p)::uuid;
$$;

-- Cuántos eventos de un tipo hay de una devolución, y su detalle. SECURITY DEFINER: audit_log no la lee nadie
-- con JWT. (created_at es igual en toda la transacción: se pide siempre por evento + fila, nunca «el último».)
create or replace function pg_temp.eventos(p_evento text, p_fila uuid) returns integer
language sql security definer as $$
  select count(*)::int from auditoria.audit_log a where a.event_type = p_evento and a.fila_id = p_fila
$$;
create or replace function pg_temp.detalle(p_evento text, p_fila uuid) returns jsonb
language sql security definer as $$
  select a.metadata from auditoria.audit_log a where a.event_type = p_evento and a.fila_id = p_fila
$$;
-- «actor|target|tabla» del evento.
create or replace function pg_temp.quien(p_evento text, p_fila uuid) returns text
language sql security definer as $$
  select coalesce(a.actor_user_id::text, 'null') || '|' || coalesce(a.target_user_id::text, 'null') || '|' || a.tabla
    from auditoria.audit_log a where a.event_type = p_evento and a.fila_id = p_fila
$$;
-- Cuántos eventos de devolución hay en total (de cualquier fila).
create or replace function pg_temp.total() returns integer
language sql security definer as $$
  select count(*)::int from auditoria.audit_log a where a.event_type in ('devolucion_registrada', 'devolucion_anulada')
$$;

-- El arreglo de productos tal como lo manda el teléfono.
create or replace function pg_temp.items(variadic p text[]) returns jsonb language sql as $$
  select jsonb_agg(jsonb_build_object('producto_id', pg_temp.u(x.p), 'cantidad', x.n,
                                      'venta_item_id', pg_temp.u(case x.p when '11' then '81' else '82' end)))
    from (select p[i] as p, p[i + 1]::int as n from generate_series(1, array_length(p, 1), 2) i) x;
$$;
-- Lo mismo con los renglones de la venta 72 (de b2).
create or replace function pg_temp.items72(variadic p text[]) returns jsonb language sql as $$
  select jsonb_agg(jsonb_build_object('producto_id', pg_temp.u(x.p), 'cantidad', x.n,
                                      'venta_item_id', pg_temp.u(case x.p when '11' then '84' else '85' end)))
    from (select p[i] as p, p[i + 1]::int as n from generate_series(1, array_length(p, 1), 2) i) x;
$$;

-- El payload de una devolución tal como lo manda el teléfono.
create or replace function pg_temp.dev(p_id uuid, p_venta uuid, p_items jsonb default null)
returns jsonb language sql as $$
  select jsonb_build_object('id', p_id, 'venta_id', p_venta,
                            'productos_devueltos', coalesce(p_items, pg_temp.items('11', '1')),
                            'dinero_retenido', 0, 'fecha_devolucion', '2026-10-05T12:00:00Z');
$$;
-- Un job de push de la entidad; devuelve el resultado.
create or replace function pg_temp.push1(p_op uuid, p_tipo text, p_payload jsonb, p_version bigint default null)
returns jsonb language sql as $$
  select sync.push(jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
           'client_op_id', p_op, 'entity', 'devolucion', 'op', p_tipo,
           'sync_version', p_version, 'payload', p_payload)))) -> 'results' -> 0;
$$;

-- «sqlstate», u «ok», de lo que hace una sentencia.
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;
-- Cuántas filas tocó una sentencia de escritura.
create or replace function pg_temp.filas(p_sql text) returns integer language plpgsql as $$
declare
  v_n integer;
begin
  execute p_sql;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Colportoras b1 y b2. Productos 11, 12. Una venta de b1 (71) y una de b2 (72).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'dev91-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('b2','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.producto (id, nombre, tipo) values
  (pg_temp.u('11'), 'Libro 1 t91', 'LIBRO'),
  (pg_temp.u('12'), 'Libro 2 t91', 'LIBRO');

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('f0'), 'Pais dev91', 'ZQ');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro)
values (pg_temp.u('f1'), 'Ciudad dev91', 'Departamento de prueba', pg_temp.u('f0'), -34.90, -56.20);
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  (pg_temp.u('a1'), 'CASA', 'Av. Italia', '100', -34.900, -56.200, pg_temp.u('f1'), pg_temp.u('b1')),
  (pg_temp.u('a2'), 'CASA', 'Calle Dos',  '2',   -34.905, -56.195, pg_temp.u('f1'), pg_temp.u('b2'));
insert into public.espacio (id, ubicacion_id, created_by) values
  (pg_temp.u('e1'), pg_temp.u('a1'), pg_temp.u('b1')),
  (pg_temp.u('e2'), pg_temp.u('a2'), pg_temp.u('b2'));
insert into public.espacio_persona (id, espacio_id, persona_id, created_by) values
  (pg_temp.u('51'), pg_temp.u('e1'), pg_temp.u('c2'), pg_temp.u('b1')),
  (pg_temp.u('53'), pg_temp.u('e2'), pg_temp.u('c4'), pg_temp.u('b2'));
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by) values
  (pg_temp.u('71'), pg_temp.u('51'), 'T-9171', 450000, '2026-10-01 15:00:00+00', pg_temp.u('b1'), pg_temp.u('b1')),
  (pg_temp.u('72'), pg_temp.u('53'), 'T-9172', 260000, '2026-10-01 16:00:00+00', pg_temp.u('b2'), pg_temp.u('b2'));
-- Cantidades holgadas: lo que se devuelve no pasa del tope del renglón (0142).
insert into public.venta_item (id, venta_id, producto_id, cantidad, precio_unitario, subtotal) values
  (pg_temp.u('81'), pg_temp.u('71'), pg_temp.u('11'), 30, 100000, 3000000),
  (pg_temp.u('82'), pg_temp.u('71'), pg_temp.u('12'), 30, 50000, 1500000),
  (pg_temp.u('84'), pg_temp.u('72'), pg_temp.u('11'), 30, 100000, 3000000),
  (pg_temp.u('85'), pg_temp.u('72'), pg_temp.u('12'), 30, 50000, 1500000);

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select has_function('public', 'tg_devolucion_auditar_alta', array[]::text[], 'existe la función del alta');
select has_function('public', 'tg_devolucion_auditar_baja', array[]::text[], 'existe la función de la baja');
select is((select count(*)::int from pg_proc p
            where p.oid in ('public.tg_devolucion_auditar_alta()'::regprocedure,
                            'public.tg_devolucion_auditar_baja()'::regprocedure)
              and p.prosecdef and p.provolatile = 'v'
              and 'search_path=""' = any (p.proconfig)), 2,
          'las dos son SECURITY DEFINER, volátiles y con el search_path vacío');
select is((select count(*)::int
             from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
            where a.privilege_type = 'EXECUTE' and a.grantee <> p.proowner
              and p.oid in ('public.tg_devolucion_auditar_alta()'::regprocedure,
                            'public.tg_devolucion_auditar_baja()'::regprocedure)), 0,
          'nadie más que el dueño las ejecuta (ni PUBLIC, ni anon, ni authenticated, ni service_role)');
select ok(not has_function_privilege('authenticated', 'public.tg_devolucion_auditar_alta()', 'execute')
          and not has_function_privilege('authenticated', 'public.tg_devolucion_auditar_baja()', 'execute'),
          'authenticated no las llama desde afuera');
select has_trigger('public', 'devolucion', 'devolucion_auditar_alta', 'devolucion tiene el trigger del alta');
select has_trigger('public', 'devolucion', 'devolucion_auditar_baja', 'y el de la baja');
select is((select array_agg(t.tgname::text || ' ' || (t.tgtype & 1)::text || ' ' || (t.tgtype & 2)::text
                            || ' ' || (t.tgtype & 4)::text || ' ' || (t.tgtype & 16)::text order by t.tgname)
             from pg_trigger t
            where t.tgrelid = 'public.devolucion'::regclass
              and t.tgname in ('devolucion_auditar_alta', 'devolucion_auditar_baja')),
          array['devolucion_auditar_alta 1 0 4 0', 'devolucion_auditar_baja 1 0 0 16'],
          'los dos son AFTER (bit BEFORE en 0) y por fila; el del alta es de INSERT y el de la baja de UPDATE');
select ok((select pg_get_triggerdef(t.oid) ~ 'AFTER UPDATE OF deleted_at ON public.devolucion'
                  and pg_get_triggerdef(t.oid) ~ 'old.deleted_at IS NULL'
                  and pg_get_triggerdef(t.oid) ~ 'new.deleted_at IS NOT NULL'
             from pg_trigger t where t.tgname = 'devolucion_auditar_baja' and t.tgrelid = 'public.devolucion'::regclass),
          'el de la baja mira solo deleted_at y solo cuando pasa de null a una fecha');
select is((select count(*)::int from pg_trigger t
            where t.tgrelid = 'public.devolucion'::regclass and not t.tgisinternal),
          7, 'devolucion tiene 7 triggers: los 2 de auditoría de siempre, el de los productos, estos 2, el que devuelve el stock (0136) y el del tope por renglón (0142)');

-- ---------------------------------------------------------------------------
-- 2. El alta deja devolucion_registrada
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
insert into public.devolucion (id, venta_id, productos_devueltos, dinero_retenido, monto_reembolsado, fecha_devolucion)
values (pg_temp.u('d1'), pg_temp.u('71'), pg_temp.items('11', '2', '12', '1'), 50000, 190000, '2026-10-05T12:00:00Z');
select pg_temp.actuar_como_servidor();

select is(pg_temp.eventos('devolucion_registrada', pg_temp.u('d1')), 1, 'registrar una devolución deja un evento');
select is(pg_temp.eventos('devolucion_anulada', pg_temp.u('d1')), 0, 'y ninguno de anulación');
select is(pg_temp.quien('devolucion_registrada', pg_temp.u('d1')), pg_temp.u('b1')::text || '|null|devolucion',
          'el actor es la colportora que la sube, sin target, sobre la tabla devolucion');
select is(pg_temp.detalle('devolucion_registrada', pg_temp.u('d1')) - 'fecha_devolucion',
          jsonb_build_object('venta_id', pg_temp.u('71'), 'productos_distintos', 2, 'unidades_devueltas', 3,
                             'dinero_retenido', 50000, 'monto_reembolsado', 190000),
          'el detalle lleva la venta, cuántos productos y unidades y los dos montos en centavos');
select is((pg_temp.detalle('devolucion_registrada', pg_temp.u('d1')) ->> 'fecha_devolucion')::timestamptz,
          '2026-10-05T12:00:00Z'::timestamptz, 'y la fecha del teléfono');
select is((select array_agg(k order by k) from jsonb_object_keys(pg_temp.detalle('devolucion_registrada', pg_temp.u('d1'))) k),
          array['dinero_retenido', 'fecha_devolucion', 'monto_reembolsado', 'productos_distintos', 'unidades_devueltas',
                'venta_id'],
          'exactamente esas seis claves: ningún texto libre, dato del cliente ni lista de productos');
select ok(auditoria.metadata_sin_datos_personales(pg_temp.detalle('devolucion_registrada', pg_temp.u('d1'))),
          'el detalle pasa la red de seguridad de 0073 (sin @ ni claves de datos personales)');

-- Sin reembolso (la mayoría): el monto va en null, no desaparece ni se inventa un 0.
select pg_temp.actuar_como(pg_temp.u('b1'));
insert into public.devolucion (id, venta_id, productos_devueltos, fecha_devolucion)
values (pg_temp.u('d2'), pg_temp.u('71'), pg_temp.items('11', '1'), '2026-10-06T12:00:00Z');
select pg_temp.actuar_como_servidor();
select is(pg_temp.eventos('devolucion_registrada', pg_temp.u('d2')), 1, 'otra devolución, otro evento');
select is(pg_temp.detalle('devolucion_registrada', pg_temp.u('d2')) -> 'monto_reembolsado', 'null'::jsonb,
          'sin reembolso: monto_reembolsado queda en null');
select is(pg_temp.detalle('devolucion_registrada', pg_temp.u('d2')) -> 'dinero_retenido', '0'::jsonb,
          'y la retención en 0');
select is(pg_temp.eventos('devolucion_registrada', pg_temp.u('d1')), 1, 'el evento de la primera no se tocó');

-- Una devolución que se rechaza (CHECK, FK) no deja evento: el AFTER no llega a correr.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de(format($$insert into public.devolucion (id, venta_id, productos_devueltos, fecha_devolucion)
                                    values (%L, %L, '[]'::jsonb, now())$$, pg_temp.u('d9'), pg_temp.u('71'))),
          '23514', 'una devolución sin productos se rechaza (23514)');
select is(pg_temp.error_de(format($$insert into public.devolucion (id, venta_id, productos_devueltos, fecha_devolucion)
                                    values (%L, %L, %L::jsonb, now())$$, pg_temp.u('d9'), pg_temp.u('72'),
                                    pg_temp.items72('11', '1')::text)),
          '42501', 'y la de una venta ajena también (42501)');
select pg_temp.actuar_como_servidor();
select is(pg_temp.eventos('devolucion_registrada', pg_temp.u('d9')), 0, 'lo rechazado no deja evento');

-- ---------------------------------------------------------------------------
-- 3. La anulación deja devolucion_anulada
-- ---------------------------------------------------------------------------
-- La ajena: b2 no ve la devolución de b1, su UPDATE no toca ninguna fila y no hay evento.
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.filas(format($$update public.devolucion set deleted_at = now() where id = %L$$, pg_temp.u('d1'))), 0,
          'b2 no puede anular la devolución de b1 (no la ve)');
select pg_temp.actuar_como_servidor();
select is(pg_temp.eventos('devolucion_anulada', pg_temp.u('d1')), 0, 'y no deja evento');

-- Otra columna de una devolución viva: no es una anulación.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.filas(format($$update public.devolucion set dinero_retenido = 60000 where id = %L$$, pg_temp.u('d1'))), 1,
          'b1 corrige la retención de su devolución');
select pg_temp.actuar_como_servidor();
select is(pg_temp.eventos('devolucion_anulada', pg_temp.u('d1')), 0, 'corregir una devolución no es anularla: sin evento');
select is(pg_temp.eventos('devolucion_registrada', pg_temp.u('d1')), 1, 'ni un segundo «registrada»');

-- Anular.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.filas(format($$update public.devolucion set deleted_at = '2026-10-07T10:00:00Z' where id = %L$$, pg_temp.u('d1'))), 1,
          'b1 anula la d1 (la baja es deleted_at)');
select pg_temp.actuar_como_servidor();
select is(pg_temp.eventos('devolucion_anulada', pg_temp.u('d1')), 1, 'anular deja un evento');
select is(pg_temp.quien('devolucion_anulada', pg_temp.u('d1')), pg_temp.u('b1')::text || '|null|devolucion',
          'con la colportora de actor, sin target, sobre la tabla devolucion');
select is(pg_temp.detalle('devolucion_anulada', pg_temp.u('d1')) - 'fecha_devolucion',
          jsonb_build_object('venta_id', pg_temp.u('71'), 'productos_distintos', 2, 'unidades_devueltas', 3,
                             'dinero_retenido', 60000, 'monto_reembolsado', 190000),
          'el detalle es el de la devolución tal como quedó (con la retención ya corregida)');
select is((select array_agg(k order by k) from jsonb_object_keys(pg_temp.detalle('devolucion_anulada', pg_temp.u('d1'))) k),
          array['dinero_retenido', 'fecha_devolucion', 'monto_reembolsado', 'productos_distintos', 'unidades_devueltas',
                'venta_id'],
          'las mismas seis claves, sin texto libre');
select is(pg_temp.eventos('devolucion_registrada', pg_temp.u('d1')), 1, 'el «registrada» sigue siendo uno (el registro solo se agrega)');
select is(pg_temp.eventos('devolucion_anulada', pg_temp.u('d2')), 0, 'la d2 no se anuló: sin evento');

-- Repetir la baja, tocar otra columna de una anulada o reactivarla: nada se suma.
select pg_temp.actuar_como(pg_temp.u('b1'));
select pg_temp.filas(format($$update public.devolucion set deleted_at = '2026-10-08T10:00:00Z' where id = %L$$, pg_temp.u('d1')));
select pg_temp.filas(format($$update public.devolucion set dinero_retenido = 1 where id = %L$$, pg_temp.u('d1')));
select pg_temp.filas(format($$update public.devolucion set deleted_at = null where id = %L$$, pg_temp.u('d1')));
select pg_temp.actuar_como_servidor();
select is(pg_temp.eventos('devolucion_anulada', pg_temp.u('d1')), 1,
          'baja repetida, otra columna y reactivar no suman un segundo evento');
select is(pg_temp.eventos('devolucion_registrada', pg_temp.u('d1')), 1, 'ni reactivarla la «registra» de nuevo');

-- Las dos anulaciones son independientes.
select pg_temp.actuar_como(pg_temp.u('b1'));
select pg_temp.filas(format($$update public.devolucion set deleted_at = now() where id = %L$$, pg_temp.u('d2')));
select pg_temp.actuar_como_servidor();
select is(pg_temp.eventos('devolucion_anulada', pg_temp.u('d2')), 1, 'anular la d2 deja su propio evento');
select is(pg_temp.eventos('devolucion_anulada', pg_temp.u('d1')), 1, 'y el de la d1 sigue siendo uno');
select is(pg_temp.detalle('devolucion_anulada', pg_temp.u('d2')) -> 'monto_reembolsado', 'null'::jsonb,
          'con el reembolso en null donde no lo hubo');

-- ---------------------------------------------------------------------------
-- 4. Registrada y anulada sin conexión: sube todo junto
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
insert into public.devolucion (id, venta_id, productos_devueltos, fecha_devolucion, deleted_at)
values (pg_temp.u('d3'), pg_temp.u('71'), pg_temp.items('12', '3'), '2026-10-09T12:00:00Z', '2026-10-09T13:00:00Z');
select pg_temp.actuar_como_servidor();
select is(pg_temp.eventos('devolucion_registrada', pg_temp.u('d3')), 1, 'una devolución que entra ya anulada deja su «registrada»');
select is(pg_temp.eventos('devolucion_anulada', pg_temp.u('d3')), 1, 'y su «anulada»: la anulación no queda sin rastro');
select is(pg_temp.detalle('devolucion_anulada', pg_temp.u('d3')), pg_temp.detalle('devolucion_registrada', pg_temp.u('d3')),
          'los dos con el mismo detalle');

-- ---------------------------------------------------------------------------
-- 5. Por sync.push
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.push1(pg_temp.op('01'), 'insert', pg_temp.dev(pg_temp.u('d4'), pg_temp.u('71'))) ->> 'outcome',
          'accepted', 'el push de una devolución se acepta');
select pg_temp.actuar_como_servidor();
select is(pg_temp.eventos('devolucion_registrada', pg_temp.u('d4')), 1, 'y deja el evento, con la colportora de actor');
select is(pg_temp.quien('devolucion_registrada', pg_temp.u('d4')), pg_temp.u('b1')::text || '|null|devolucion',
          'el actor sale del JWT del push');

select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.push1(pg_temp.op('01'), 'insert', pg_temp.dev(pg_temp.u('d4'), pg_temp.u('71'))) ->> 'outcome',
          'duplicate', 'el mismo client_op_id otra vez es duplicate');
select is(pg_temp.push1(pg_temp.op('02'), 'insert', pg_temp.dev(pg_temp.u('d4'), pg_temp.u('71'))) ->> 'outcome',
          'duplicate', 'y el mismo id con otro client_op_id (reinstalar y reintentar), también');
select pg_temp.actuar_como_servidor();
select is(pg_temp.eventos('devolucion_registrada', pg_temp.u('d4')), 1, 'el reintento no duplica el evento');

-- Lo que se rechaza no deja evento.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.push1(pg_temp.op('03'), 'insert', pg_temp.dev(pg_temp.u('d5'), pg_temp.u('72'), pg_temp.items72('11', '1'))) ->> 'outcome',
          'invalid', 'una devolución sobre la venta de otra vuelve invalid');
select is(pg_temp.push1(pg_temp.op('04'), 'insert', pg_temp.dev(pg_temp.u('d6'), pg_temp.u('71'), '[]'::jsonb)) ->> 'outcome',
          'invalid', 'y la que no tiene productos también');
select pg_temp.actuar_como_servidor();
select is(pg_temp.eventos('devolucion_registrada', pg_temp.u('d5')) + pg_temp.eventos('devolucion_registrada', pg_temp.u('d6')),
          0, 'las rechazadas no dejan evento');

-- La baja por push.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.push1(pg_temp.op('05'), 'delete', jsonb_build_object('id', pg_temp.u('d4')), 0) ->> 'outcome',
          'accepted', 'b1 anula la d4 por push');
select pg_temp.actuar_como_servidor();
select is(pg_temp.eventos('devolucion_anulada', pg_temp.u('d4')), 1, 'y queda el evento de la anulación');
select is((select deleted_at is not null from public.devolucion where id = pg_temp.u('d4')), true, 'la fila quedó dada de baja');

select pg_temp.actuar_como(pg_temp.u('b1'));
select pg_temp.push1(pg_temp.op('05'), 'delete', jsonb_build_object('id', pg_temp.u('d4')), 0);
select pg_temp.push1(pg_temp.op('06'), 'delete', jsonb_build_object('id', pg_temp.u('d4')));
select pg_temp.actuar_como_servidor();
select is(pg_temp.eventos('devolucion_anulada', pg_temp.u('d4')), 1,
          'repetir la baja (mismo client_op_id, o uno nuevo) no suma otro evento');
select is(pg_temp.eventos('devolucion_registrada', pg_temp.u('d4')), 1, 'ni toca el «registrada»');

-- Una devolución enorme: el detalle tiene tamaño fijo y ni el push ni la anulación fallan (el CHECK de
-- audit_log.metadata admite 4000 caracteres; copiar 60 renglones lo pasaba, ~75 caracteres cada uno).
insert into public.producto (id, nombre, tipo)
select ('01920000-0000-7000-8000-00000091' || lpad(to_hex(i), 4, '0'))::uuid, 'Libro masivo ' || i || ' t91', 'LIBRO'
  from generate_series(1, 120) i;
-- Un renglón de la venta 71 por cada libro masivo (0136: la devolución dice de qué renglón sale cada libro).
insert into public.venta_item (id, venta_id, producto_id, cantidad, precio_unitario, subtotal)
select ('01920000-0000-7000-8000-00000092' || lpad(to_hex(i), 4, '0'))::uuid, pg_temp.u('71'),
       ('01920000-0000-7000-8000-00000091' || lpad(to_hex(i), 4, '0'))::uuid, 2, 1000, 2000
  from generate_series(1, 120) i;
create or replace function pg_temp.muchos(p_n int) returns jsonb language sql as $$
  select jsonb_agg(jsonb_build_object('producto_id', ('01920000-0000-7000-8000-00000091' || lpad(to_hex(i), 4, '0'))::uuid,
                                      'cantidad', 2,
                                      'venta_item_id', ('01920000-0000-7000-8000-00000092' || lpad(to_hex(i), 4, '0'))::uuid))
    from generate_series(1, p_n) i;
$$;
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.push1(pg_temp.op('07'), 'insert', pg_temp.dev(pg_temp.u('d7'), pg_temp.u('71'), pg_temp.muchos(120))) ->> 'outcome',
          'accepted', 'una devolución de 120 renglones se acepta por push (el detalle no copia la lista)');
select is(pg_temp.push1(pg_temp.op('08'), 'delete', jsonb_build_object('id', pg_temp.u('d7')), 0) ->> 'outcome',
          'accepted', 'y se puede anular');
select pg_temp.actuar_como_servidor();
select is(pg_temp.eventos('devolucion_registrada', pg_temp.u('d7')), 1, 'la de 120 renglones deja su «registrada»');
select is(pg_temp.eventos('devolucion_anulada', pg_temp.u('d7')), 1, 'y su «anulada»');
select is(pg_temp.detalle('devolucion_registrada', pg_temp.u('d7')) - 'fecha_devolucion',
          jsonb_build_object('venta_id', pg_temp.u('71'), 'productos_distintos', 120, 'unidades_devueltas', 240,
                             'dinero_retenido', 0, 'monto_reembolsado', null),
          'con los totales (120 productos, 240 unidades)');
select ok((select length(a.metadata::text) < 400 from auditoria.audit_log a
            where a.event_type = 'devolucion_registrada' and a.fila_id = pg_temp.u('d7')),
          'y el mismo tamaño corto de siempre');

-- El total: 5 registradas (d1, d2, d3, d4, d7; las rechazadas no cuentan) y 5 anuladas (las mismas).
select is(pg_temp.total(), 10, '5 registradas y 5 anuladas en total: nada de más, nada de menos');

select * from finish();
rollback;
