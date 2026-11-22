-- pgTAP · 0140 (backend-supabase#201, decisiones «Deshacer tr.» y «Campaña tr.» del 27/10, seguimiento de 0126):
--   1. La forma: deshacer_decision_de_transferencia, y `deshacer_hasta` en autorizar, rechazar y la bandeja.
--   2. Deshacer una autorizada: el stock, la deuda, los movimientos y los costos vuelven; vuelve a esperar;
--      se puede decidir otra vez; el reintento no hace nada.
--   3. Deshacer una rechazada, fuera de plazo, por otra persona, una que no se decidió, una cancelada.
--   4. El stock negativo de quien recibió (ya entregó esos libros).
--   5. Campaña en curso el día que se pidió: la ve y la decide quien coordina la campaña vigente; lo pedido antes
--      del inicio de otra lo decide el ADMIN.
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
create or replace function pg_temp.u(p text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000140' || p)::uuid;
$$;
create or replace function pg_temp.como(p_uid uuid, p_sql text) returns jsonb language plpgsql as $$
declare
  v_r jsonb;
begin
  perform pg_temp.actuar_como(p_uid);
  begin
    execute format('select coalesce(jsonb_agg(to_jsonb(t)), ''[]''::jsonb) from (%s) t', p_sql) into v_r;
  exception when others then
    v_r := jsonb_build_object('error', sqlstate, 'mensaje', sqlerrm);
  end;
  perform pg_temp.actuar_como_servidor();
  return v_r;
end $$;
create or replace function pg_temp.aut(p_uid uuid, p_t text) returns jsonb language sql as $$
  select pg_temp.como(p_uid, format('select * from public.autorizar_transferencia(%L)', pg_temp.u(p_t)))
$$;
create or replace function pg_temp.rech(p_uid uuid, p_t text) returns jsonb language sql as $$
  select pg_temp.como(p_uid, format('select * from public.rechazar_transferencia(%L, %L)', pg_temp.u(p_t), 'No hay libros'))
$$;
create or replace function pg_temp.desh(p_uid uuid, p_t text) returns jsonb language sql as $$
  select pg_temp.como(p_uid, format('select * from public.deshacer_decision_de_transferencia(%L)', pg_temp.u(p_t)))
$$;
create or replace function pg_temp.lista(p_uid uuid, p_camp text) returns jsonb language sql as $$
  select pg_temp.como(p_uid, format('select * from public.transferencias_de_campania(%L)', pg_temp.u(p_camp)))
$$;
-- Los sufijos de la bandeja, en el orden en que salen.
create or replace function pg_temp.ids(p_uid uuid, p_camp text) returns text language sql as $$
  select coalesce(string_agg(right(e ->> 'transferencia_id', 2), ',' order by o), '')
    from jsonb_array_elements((select case when jsonb_typeof(l) = 'array' then l else '[]'::jsonb end
                                 from (select pg_temp.lista(p_uid, p_camp) l) q)) with ordinality t(e, o)
$$;
create or replace function pg_temp.deuda(p_col text) returns bigint language sql as $$
  select coalesce((select deuda_total from public.cuenta_colportor
                    where usuario_id = pg_temp.u(p_col) and deleted_at is null), -1)
$$;
create or replace function pg_temp.stock(p_col text, p_prod text) returns integer language sql as $$
  select coalesce((select cantidad_disponible from public.stock
                    where usuario_id = pg_temp.u(p_col) and producto_id = pg_temp.u(p_prod) and deleted_at is null), -99)
$$;
create or replace function pg_temp.estado(p_t text) returns text language sql as $$
  select estado from public.transferencia_stock where id = pg_temp.u(p_t)
$$;
create or replace function pg_temp.movs_vivos(p_t text) returns bigint language sql as $$
  select count(*) from public.movimiento_stock where transferencia_id = pg_temp.u(p_t) and deleted_at is null
$$;
create or replace function pg_temp.movs_todos(p_t text) returns bigint language sql as $$
  select count(*) from public.movimiento_stock where transferencia_id = pg_temp.u(p_t)
$$;
create or replace function pg_temp.n_audit(p_evento text, p_t text) returns bigint language sql as $$
  select count(*) from auditoria.audit_log where event_type = p_evento and fila_id = pg_temp.u(p_t)
$$;
-- Una transferencia pendiente: id, de, a, y las líneas 91 × 2 y 92 × 1.
create or replace function pg_temp.nueva(p_id text, p_de text, p_a text) returns void language plpgsql as $$
begin
  insert into public.transferencia_stock (id, origen_id, destino_id, fecha_solicitud)
  values (pg_temp.u(p_id), pg_temp.u(p_de), pg_temp.u(p_a), now());
  insert into public.transferencia_item (transferencia_id, producto_id, cantidad) values
    (pg_temp.u(p_id), pg_temp.u('91'), 2), (pg_temp.u(p_id), pg_temp.u('92'), 1);
end $$;

-- --- fixtures ------------------------------------------------------------------
-- Staff: c1 coordinador de Actual (en curso); c2 de Proxima (empieza en 20 días); ad admin.
-- Colportores: b1 y b2 en Actual y Proxima; b5 y b6 solo en Proxima. Libros 91 (1500) y 92 (2500).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'transf140-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['c1','c2','ad','b1','b2','b5','b6']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('c1','COORDINADOR'), ('c2','COORDINADOR'), ('ad','ADMIN'), ('b1','COLPORTOR'), ('b2','COLPORTOR'),
               ('b5','COLPORTOR'), ('b6','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'Actual 140',  'VERANO', public.hoy_montevideo() - 30, public.hoy_montevideo() + 10, pg_temp.u('c1')),
  (pg_temp.u('e2'), 'Proxima 140', 'VERANO', public.hoy_montevideo() + 20, public.hoy_montevideo() + 80, pg_temp.u('c2'));
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), now() - interval '40 days'),
  (pg_temp.u('e1'), pg_temp.u('b2'), now() - interval '40 days'),
  (pg_temp.u('e2'), pg_temp.u('b1'), now() - interval '40 days'),
  (pg_temp.u('e2'), pg_temp.u('b2'), now() - interval '40 days'),
  (pg_temp.u('e2'), pg_temp.u('b5'), now() - interval '40 days'),
  (pg_temp.u('e2'), pg_temp.u('b6'), now() - interval '40 days');
insert into public.producto (id, nombre, tipo, precio_base_compra) values
  (pg_temp.u('91'), 'Libro Uno t140', 'LIBRO', 1500), (pg_temp.u('92'), 'Libro Dos t140', 'LIBRO', 2500);
insert into public.stock (usuario_id, producto_id, cantidad_disponible) values
  (pg_temp.u('b1'), pg_temp.u('91'), 5), (pg_temp.u('b1'), pg_temp.u('92'), 3),
  (pg_temp.u('b2'), pg_temp.u('91'), 1), (pg_temp.u('b5'), pg_temp.u('91'), 4), (pg_temp.u('b5'), pg_temp.u('92'), 4);
insert into public.cuenta_colportor (usuario_id, deuda_total) values (pg_temp.u('b1'), 20000);

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select is((select has_function_privilege('authenticated', 'public.deshacer_decision_de_transferencia(uuid)', 'execute')), true,
          'authenticated ejecuta deshacer_decision_de_transferencia');
select is((select has_function_privilege('anon', 'public.deshacer_decision_de_transferencia(uuid)', 'execute')), false, 'anon no');
select is((select has_function_privilege('authenticated', 'public.autorizar_transferencia(uuid)', 'execute')), true,
          'y siguen con sus permisos: autorizar');
select is((select has_function_privilege('authenticated', 'public.rechazar_transferencia(uuid,text)', 'execute')), true, 'rechazar');
select is((select has_function_privilege('authenticated', 'public.transferencias_de_campania(uuid)', 'execute')), true, 'y la bandeja');
select is((select has_function_privilege('anon', 'public.transferencias_de_campania(uuid)', 'execute')), false, 'anon no la lee');
select ok((select proargnames @> array['deshacer_hasta'] from pg_proc where oid = 'public.autorizar_transferencia(uuid)'::regprocedure),
          'autorizar devuelve deshacer_hasta');
select ok((select proargnames @> array['deshacer_hasta'] from pg_proc where oid = 'public.rechazar_transferencia(uuid,text)'::regprocedure),
          'rechazar también');
select ok((select proargnames @> array['deshacer_hasta'] from pg_proc where oid = 'public.transferencias_de_campania(uuid)'::regprocedure),
          'y la bandeja');

-- ---------------------------------------------------------------------------
-- 2. Deshacer una autorizada
-- ---------------------------------------------------------------------------
select pg_temp.nueva('11', 'b1', 'b2');
select is(pg_temp.aut(pg_temp.u('c1'), '11') -> 0 ->> 'estado', 'AUTORIZADO', 'c1 autoriza');
select is(pg_temp.stock('b1', '91') || '/' || pg_temp.stock('b1', '92') || '/' || pg_temp.stock('b2', '91') || '/' || pg_temp.stock('b2', '92'),
          '3/2/3/1', 'el stock pasó de b1 a b2');
select is(pg_temp.deuda('b1') || '/' || pg_temp.deuda('b2'), '14500/5500', 'y la deuda (2 × 1500 + 2500 = 5500)');
select is(pg_temp.movs_vivos('11'), 4::bigint, 'con cuatro movimientos');
select ok(pg_temp.aut(pg_temp.u('c1'), '11') -> 0 ->> 'deshacer_hasta' is not null, 'autorizar dice hasta cuándo se puede deshacer');
select is((pg_temp.lista(pg_temp.u('c1'), 'e1') -> 0 ->> 'deshacer_hasta')::timestamptz,
          (pg_temp.lista(pg_temp.u('c1'), 'e1') -> 0 ->> 'decidido_en')::timestamptz + interval '8 seconds',
          'y la bandeja lo trae: decidido_en + 8 s');

select is(pg_temp.desh(pg_temp.u('c1'), '11') -> 0 ->> 'estado', 'PENDIENTE_AUTORIZACION', 'c1 la deshace: vuelve a esperar');
select is(pg_temp.stock('b1', '91') || '/' || pg_temp.stock('b1', '92') || '/' || pg_temp.stock('b2', '91') || '/' || pg_temp.stock('b2', '92'),
          '5/3/1/0', 'el stock vuelve (b2 queda en 0 de lo que recibió: 1 y 0)');
select is(pg_temp.deuda('b1') || '/' || pg_temp.deuda('b2'), '20000/0', 'la deuda vuelve');
select is(pg_temp.movs_vivos('11') || '/' || pg_temp.movs_todos('11'), '0/4', 'los cuatro movimientos quedan dados de baja, no borrados');
select is((select (coordinador_id is null, decidido_en is null, monto_deuda is null, motivo_rechazo is null)::text
             from public.transferencia_stock where id = pg_temp.u('11')), '(t,t,t,t)', 'sin coordinador, decisión, deuda ni motivo');
select is((select count(*)::int from public.transferencia_item where transferencia_id = pg_temp.u('11') and precio_unitario is not null), 0,
          'y sin costo fijado en las líneas');
select is(pg_temp.n_audit('transferencia_decision_deshecha', '11'), 1::bigint, 'deja el evento transferencia_decision_deshecha');
select is((select array(select k from jsonb_object_keys(a.metadata) k order by k) from auditoria.audit_log a
            where a.event_type = 'transferencia_decision_deshecha' and a.fila_id = pg_temp.u('11')),
          array['decision_deshecha','destino_id','monto_deuda','origen_id'], 'con solo ids y números');

-- Reintento: ya_estaba, sin tocar nada.
select is(pg_temp.desh(pg_temp.u('c1'), '11') -> 0 ->> 'ya_estaba', 'true', 'deshacerla otra vez: ya_estaba = true');
select is(pg_temp.stock('b1', '91') || '/' || pg_temp.deuda('b1') || '/' || pg_temp.n_audit('transferencia_decision_deshecha', '11'),
          '5/20000/1', 'sin devolver de más ni sumar otro evento');

-- Dos acciones seguidas: autorizar de nuevo (mueve otra vez, con movimientos nuevos), deshacer de nuevo.
select is(pg_temp.aut(pg_temp.u('c1'), '11') -> 0 ->> 'estado', 'AUTORIZADO', 'se puede volver a autorizar');
select is(pg_temp.stock('b1', '91') || '/' || pg_temp.deuda('b2') || '/' || pg_temp.movs_vivos('11') || '/' || pg_temp.movs_todos('11'),
          '3/5500/4/8', 'mueve otra vez, con cuatro movimientos nuevos');
select is(pg_temp.desh(pg_temp.u('c1'), '11') -> 0 ->> 'estado', 'PENDIENTE_AUTORIZACION', 'y se puede volver a deshacer');
select is(pg_temp.stock('b1', '91') || '/' || pg_temp.deuda('b1') || '/' || pg_temp.movs_vivos('11'), '5/20000/0', 'como la primera vez');

-- ---------------------------------------------------------------------------
-- 3. Rechazada, fuera de plazo, otra persona, sin decidir, cancelada
-- ---------------------------------------------------------------------------
select pg_temp.nueva('12', 'b1', 'b2');
select ok(pg_temp.rech(pg_temp.u('c1'), '12') -> 0 ->> 'deshacer_hasta' is not null, 'rechazar también dice hasta cuándo');
select is(pg_temp.desh(pg_temp.u('c1'), '12') -> 0 ->> 'estado', 'PENDIENTE_AUTORIZACION', 'se deshace una rechazada');
select is((select motivo_rechazo is null from public.transferencia_stock where id = pg_temp.u('12')), true, 'y se borra el motivo');
select is(pg_temp.stock('b1', '91') || '/' || pg_temp.deuda('b1'), '5/20000', 'sin tocar stock ni deuda');

select is(pg_temp.desh(pg_temp.u('c1'), '12') -> 0 ->> 'ya_estaba', 'true', 'una que no se decidió: ya_estaba (nada que deshacer)');

select pg_temp.aut(pg_temp.u('c1'), '12');
select is(pg_temp.desh(pg_temp.u('ad'), '12') ->> 'error', 'TR006', 'otra persona (aunque sea ADMIN) no la deshace: TR006');
select is(pg_temp.estado('12'), 'AUTORIZADO', 'y sigue autorizada');
update public.transferencia_stock set decidido_en = now() - interval '9 seconds' where id = pg_temp.u('12');
select is(pg_temp.desh(pg_temp.u('c1'), '12') -> 0 ->> 'estado', 'PENDIENTE_AUTORIZACION', 'a los 9 s todavía entra (8 s + 2 de gracia)');
select pg_temp.aut(pg_temp.u('c1'), '12');
update public.transferencia_stock set decidido_en = now() - interval '11 seconds' where id = pg_temp.u('12');
select is(pg_temp.desh(pg_temp.u('c1'), '12') ->> 'error', 'TR006', 'a los 11 s ya no: TR006');
select is(pg_temp.estado('12') || '/' || pg_temp.stock('b2', '91'), 'AUTORIZADO/3', 'sigue autorizada y el stock donde estaba');
select is(pg_temp.desh(pg_temp.u('c2'), '12') ->> 'error', '42501', 'un coordinador de otra campaña: 42501');
select is(pg_temp.desh(pg_temp.u('b1'), '12') ->> 'error', '42501', 'un colportor: 42501');
select is(pg_temp.desh(null, '12') ->> 'error', '42501', 'sin sesión: 42501');
select is(pg_temp.como(pg_temp.u('c1'), format('select * from public.deshacer_decision_de_transferencia(%L)', pg_temp.u('ff'))) ->> 'error',
          'TR001', 'una que no existe: TR001');
update public.transferencia_stock set estado = 'CANCELADO', decidido_en = null, coordinador_id = null where id = pg_temp.u('12');
select is(pg_temp.desh(pg_temp.u('c1'), '12') ->> 'error', 'TR006', 'una cancelada ya siguió su camino: TR006');

-- ---------------------------------------------------------------------------
-- 4. El stock negativo de quien recibió
-- ---------------------------------------------------------------------------
select pg_temp.nueva('13', 'b1', 'b2');
select pg_temp.aut(pg_temp.u('c1'), '13');
update public.stock set cantidad_disponible = 0 where usuario_id = pg_temp.u('b2') and producto_id = pg_temp.u('91');
select is(pg_temp.desh(pg_temp.u('c1'), '13') -> 0 ->> 'estado', 'PENDIENTE_AUTORIZACION',
          'b2 ya entregó los libros en esos segundos: igual se deshace');
select is(pg_temp.stock('b2', '91'), -2, 'y su stock queda negativo (S46), la señal de siempre');

-- ---------------------------------------------------------------------------
-- 5. Campaña en curso el día que se pidió
-- ---------------------------------------------------------------------------
-- 14: b1 → b2 hoy: de Actual. 15: b5 → b6 hoy: Proxima no empezó, no es de ninguna. 16: b1 → b2 pedida el día
-- que empieza Proxima (+20): de Proxima.
select pg_temp.nueva('14', 'b1', 'b2');
select pg_temp.nueva('15', 'b5', 'b6');
select pg_temp.nueva('16', 'b1', 'b2');
update public.transferencia_stock set fecha_solicitud = (public.hoy_montevideo() + 21)::timestamptz + interval '15 hours'
 where id = pg_temp.u('16');
select ok(strpos(pg_temp.ids(pg_temp.u('c1'), 'e1'), '14') > 0, 'Actual (c1) ve la de hoy entre b1 y b2');
select ok(strpos(pg_temp.ids(pg_temp.u('c1'), 'e1'), '16') = 0, 'pero no la que se pidió ya empezada la próxima');
select ok(strpos(pg_temp.ids(pg_temp.u('c1'), 'e1'), '15') = 0, 'ni la de b5 y b6, que no están en Actual');
select ok(strpos(pg_temp.ids(pg_temp.u('c2'), 'e2'), '14') = 0, 'Proxima (c2) NO ve la de hoy entre b1 y b2: todavía no empezó');
select ok(strpos(pg_temp.ids(pg_temp.u('c2'), 'e2'), '15') = 0, 'ni la de b5 y b6 de hoy: antes del inicio no es de ninguna');
select ok(strpos(pg_temp.ids(pg_temp.u('c2'), 'e2'), '16') > 0, 'pero sí la que se pidió con la campaña empezada');
select is(pg_temp.aut(pg_temp.u('c2'), '14') ->> 'error', '42501', 'c2 no puede decidir la de hoy entre b1 y b2');
select is(pg_temp.aut(pg_temp.u('c2'), '15') ->> 'error', '42501', 'ni la de b5 y b6 de hoy');
select is(pg_temp.estado('15'), 'PENDIENTE_AUTORIZACION', 'que sigue esperando');
select is(pg_temp.aut(pg_temp.u('c1'), '14') -> 0 ->> 'estado', 'AUTORIZADO', 'c1 sí decide la de Actual');
select is(pg_temp.aut(pg_temp.u('c1'), '15') ->> 'error', '42501', 'y c1 no la de b5 y b6');
select is(pg_temp.ids(pg_temp.u('ad'), 'e2') like '%15%' or pg_temp.ids(pg_temp.u('ad'), 'e1') like '%15%', false,
          'ninguna bandeja de campaña lista la de antes del inicio...');
select is(pg_temp.aut(pg_temp.u('ad'), '15') -> 0 ->> 'estado', 'AUTORIZADO', '...pero el ADMIN la decide');

select * from finish();
rollback;
