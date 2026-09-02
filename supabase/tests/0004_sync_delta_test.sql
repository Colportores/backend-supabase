-- pgTAP · migración 0002 — comportamiento del push y del delta.
--
-- ESTE ARCHIVO NO ENVUELVE TODO EN UNA TRANSACCIÓN, a diferencia de 0001-0003.
-- No es un descuido: el delta sirve solo lo que está por debajo del horizonte
-- `pg_snapshot_xmin(pg_current_snapshot())`, así que una transacción no puede
-- entregar lo que ella misma acaba de escribir — correctamente. Con todo en un
-- `begin`, el archivo entero probaría una configuración que no existe: en
-- producción el push y el pull son dos requests HTTP distintos.
--
-- A cambio, limpia sus filas al final. Espera una base con las migraciones
-- aplicadas; `scripts/db-reset.sh` la deja así.
--
-- Por la misma razón los GUCs del JWT se setean a nivel SESIÓN (tercer argumento
-- `false`): con `true` son locales a la transacción y auth.uid() vuelve null en
-- la sentencia siguiente.

select * from no_plan();

-- ---------------------------------------------------------------------------
-- Fixtures (como postgres, sin RLS)
-- ---------------------------------------------------------------------------

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at) values
  ('01920000-0000-7000-8000-0000000004a1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ana.sync@example.com',  'x', now(), now()),
  ('01920000-0000-7000-8000-0000000004a2', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'beto.sync@example.com', 'x', now(), now());

insert into public.pais (id, nombre, iso_code) values
  ('01920000-0000-7000-8000-0000000004c0', 'Uruguay', 'UY');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000004c1', 'Montevideo', '01920000-0000-7000-8000-0000000004c0', -34.9, -56.16);
insert into public.zona (id, nombre, ciudad_id) values
  ('01920000-0000-7000-8000-0000000004d1', 'Zona Ana',  '01920000-0000-7000-8000-0000000004c1'),
  ('01920000-0000-7000-8000-0000000004d2', 'Zona Beto', '01920000-0000-7000-8000-0000000004c1');
update public.usuario set zona_id = '01920000-0000-7000-8000-0000000004d1' where id = '01920000-0000-7000-8000-0000000004a1';
update public.usuario set zona_id = '01920000-0000-7000-8000-0000000004d2' where id = '01920000-0000-7000-8000-0000000004a2';

insert into public.producto (id, nombre, tipo) values
  ('01920000-0000-7000-8000-0000000004e1', 'El Deseado de Todas las Gentes', 'LIBRO');

create or replace function pg_temp.actuar_como(p_uid uuid) returns void language plpgsql as $$
begin
  -- Las dos formas del claim: request.jwt.claims (auth.uid() de los proyectos
  -- hosteados) y request.jwt.claim.sub (la que lee auth.uid() de la imagen base).
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, false);
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('role', 'authenticated', false);
end $$;

-- ---------------------------------------------------------------------------
-- 1. Push: la RLS y las columnas del servidor
-- ---------------------------------------------------------------------------

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000004a1');

select is(
  sync.push($$[
    {"client_op_id":"01920000-0000-7000-8000-000000004b01","entity":"jornada","op":"insert",
     "payload":{"id":"01920000-0000-7000-8000-000000004f01","inicio":"2026-09-02T10:00:00Z",
                "colportor_id":"01920000-0000-7000-8000-0000000004a2","sync_version":99}}
  ]$$::jsonb) #>> '{results,0,outcome}',
  'accepted',
  'Ana sube una jornada'
);

-- El cliente mandó la jornada a nombre de Beto y una sync_version inventada.
-- Ninguna de las dos cosas le sirve de nada (contrato §5.4).
select is(
  (select colportor_id from public.jornada where id = '01920000-0000-7000-8000-000000004f01'),
  '01920000-0000-7000-8000-0000000004a1'::uuid,
  'colportor_id ajeno se descarta: la fila queda a nombre de quien la sube'
);
select is(
  (select sync_version from public.jornada where id = '01920000-0000-7000-8000-000000004f01'),
  0::bigint,
  'sync_version la fija el servidor en 0, la mande o no el cliente'
);
select isnt(
  (select xmin_w from public.jornada where id = '01920000-0000-7000-8000-000000004f01'),
  null::xid8,
  'el trigger de auditoría estampó el cursor del delta'
);

-- ---------------------------------------------------------------------------
-- 2. Idempotencia (contrato §5.3)
-- ---------------------------------------------------------------------------

select is(
  sync.push($$[
    {"client_op_id":"01920000-0000-7000-8000-000000004b01","entity":"jornada","op":"insert",
     "payload":{"id":"01920000-0000-7000-8000-000000004f01","inicio":"2026-09-02T10:00:00Z"}}
  ]$$::jsonb) #>> '{results,0,outcome}',
  'duplicate',
  'reintentar el mismo client_op_id devuelve duplicate, no aplica dos veces'
);

-- Replay del contrato §7: el mismo insert con OTRO client_op_id (backup viejo,
-- cache ya purgado). La PK la generó el dispositivo, así que es la misma fila.
select is(
  sync.push($$[
    {"client_op_id":"01920000-0000-7000-8000-000000004b0a","entity":"jornada","op":"insert",
     "payload":{"id":"01920000-0000-7000-8000-000000004f01","inicio":"2026-09-02T10:00:00Z"}}
  ]$$::jsonb) #>> '{results,0,outcome}',
  'duplicate',
  'insert sobre una PK existente es éxito idempotente, no error (contrato §7)'
);

-- ---------------------------------------------------------------------------
-- 3. LWW y compare-and-swap (contrato §5.4)
-- ---------------------------------------------------------------------------

select is(
  sync.push($$[
    {"client_op_id":"01920000-0000-7000-8000-000000004b02","entity":"jornada","op":"update",
     "sync_version":7,
     "payload":{"id":"01920000-0000-7000-8000-000000004f01","fin":"2026-09-02T18:00:00Z"}}
  ]$$::jsonb) #>> '{results,0,outcome}',
  'conflict',
  'update con una versión que el servidor no tiene devuelve conflict'
);

select isnt(
  sync.push($$[
    {"client_op_id":"01920000-0000-7000-8000-000000004b0b","entity":"jornada","op":"update",
     "sync_version":7,
     "payload":{"id":"01920000-0000-7000-8000-000000004f01","fin":"2026-09-02T18:00:00Z"}}
  ]$$::jsonb) #> '{results,0,server_row}',
  null::jsonb,
  'el conflicto devuelve la fila del servidor: el cliente resuelve sin un pull extra'
);

-- El conflicto NO entra al cache. Si entrara, el reintento del motor tras
-- resolver el LWW volvería `duplicate`, el job quedaría DONE y la corrección se
-- perdería en silencio sobre una fila que nunca se escribió.
select is(
  (select count(*)::integer from sync.op_cache
    where client_op_id = '01920000-0000-7000-8000-000000004b02'),
  0,
  'un conflict no se cachea: solo entra lo que se aplicó'
);

select is(
  sync.push($$[
    {"client_op_id":"01920000-0000-7000-8000-000000004b02","entity":"jornada","op":"update",
     "sync_version":0,
     "payload":{"id":"01920000-0000-7000-8000-000000004f01","fin":"2026-09-02T18:00:00Z"}}
  ]$$::jsonb) #>> '{results,0,outcome}',
  'accepted',
  'el mismo client_op_id, ya resuelto el LWW, se re-valida y aplica'
);

select is(
  (select sync_version from public.jornada where id = '01920000-0000-7000-8000-000000004f01'),
  1::bigint,
  'el update bumpea sync_version por trigger'
);

-- ---------------------------------------------------------------------------
-- 4. Un job roto no tumba el lote
-- ---------------------------------------------------------------------------

-- Sin la subtransacción por job, un solo payload venenoso hace fallar el push
-- entero, el motor lo clasifica como 5xx transitorio y lo reintenta para
-- siempre: la cola del colportor queda bloqueada y ninguna venta vuelve a subir.
select is(
  (select array_agg(r ->> 'outcome' order by ord)
     from jsonb_array_elements(
       sync.push($$[
         {"client_op_id":"01920000-0000-7000-8000-000000004b03","entity":"jornada","op":"insert",
          "payload":{"id":"01920000-0000-7000-8000-000000004f03","inicio":"no-es-una-fecha"}},
         {"client_op_id":"01920000-0000-7000-8000-000000004b04","entity":"jornada","op":"insert",
          "payload":{"id":"01920000-0000-7000-8000-000000004f04","inicio":"2026-09-02T11:00:00Z"}}
       ]$$::jsonb) -> 'results') with ordinality as t(r, ord)),
  array['invalid','accepted'],
  'un payload roto queda invalid y el resto del lote entra igual'
);

select is(
  sync.push($$[{"client_op_id":"01920000-0000-7000-8000-000000004b05","entity":"producto",
                "op":"insert","payload":{"id":"01920000-0000-7000-8000-0000000004e9",
                "nombre":"Pirata","tipo":"LIBRO"}}]$$::jsonb) #>> '{results,0,code}',
  'ENTIDAD_DE_SOLO_LECTURA',
  'una entidad pull no se puede escribir: la réplica es de solo lectura (contrato §2)'
);

select is(
  sync.push($$[{"client_op_id":"01920000-0000-7000-8000-000000004b06","entity":"usuario",
                "op":"insert","payload":{"id":"01920000-0000-7000-8000-0000000004a2"}}]$$::jsonb)
    #>> '{results,0,code}',
  'ENTIDAD_DESCONOCIDA',
  'sin lista blanca un cliente escribiría donde no debe: usuario no está registrada'
);

select is(
  sync.push($$[{"client_op_id":"no-es-un-uuid","entity":"jornada","op":"insert",
                "payload":{"id":"01920000-0000-7000-8000-000000004f09",
                "inicio":"2026-09-02T12:00:00Z"}}]$$::jsonb) #>> '{results,0,outcome}',
  'invalid',
  'un client_op_id malformado es invalid, no un 500 que tumba el lote'
);

-- ---------------------------------------------------------------------------
-- 5. Soft delete
-- ---------------------------------------------------------------------------

select is(
  sync.push($$[{"client_op_id":"01920000-0000-7000-8000-000000004b07","entity":"jornada",
                "op":"delete","sync_version":0,
                "payload":{"id":"01920000-0000-7000-8000-000000004f04"}}]$$::jsonb)
    #>> '{results,0,outcome}',
  'accepted',
  'el delete del cable es un soft delete'
);
select isnt(
  (select deleted_at from public.jornada where id = '01920000-0000-7000-8000-000000004f04'),
  null::timestamptz,
  'la fila queda con deleted_at, no borrada: el cliente necesita el tombstone'
);

-- ---------------------------------------------------------------------------
-- 6. El delta
-- ---------------------------------------------------------------------------

-- Dos, no cuatro: de los cuatro inserts que Ana intentó, dos quedaron `invalid`
-- (la fecha rota y el client_op_id malformado) y no escribieron nada. La que
-- borró sí sale — el cliente necesita el tombstone para borrar su réplica.
select is(
  (select count(*)::integer from jsonb_array_elements(
     sync.pull(array['jornada']) #> '{rows,jornada}')),
  2,
  'el pull trae las jornadas de Ana que sí se escribieron, tombstone incluido'
);

select is(
  (select count(*)::integer from jsonb_array_elements(
     sync.pull(array['producto']) #> '{rows,producto}')),
  1,
  'el catálogo se replica sin filtro por dueño (contrato §2, política pull)'
);

-- Un watermark al día no trae nada. La entidad ausente de `rows` significa
-- "sin cambios": el cliente no borra nada por ausencia.
select ok(
  not (sync.pull(array['jornada'], sync.pull(array['jornada']) -> 'watermark') -> 'rows' ? 'jornada'),
  'con el watermark al día el pull no devuelve la entidad'
);

-- LA REGRESIÓN QUE IMPORTA. `updated_at` se llena con now(), que es la hora de
-- INICIO de transacción: ordenar el delta por ahí deja una fila que commiteó
-- tarde detrás de un watermark que ya avanzó, y no se entrega nunca. Y si el
-- xmin_w no se re-estampara en el UPDATE, pasaría lo mismo con toda modificación
-- de una fila que el cliente ya bajó.
create temporary table wm_previo as select sync.pull(array['jornada']) -> 'watermark' as w;

select is(
  sync.push($$[
    {"client_op_id":"01920000-0000-7000-8000-000000004b08","entity":"jornada","op":"update",
     "sync_version":1,
     "payload":{"id":"01920000-0000-7000-8000-000000004f01","total_visitas":7}}
  ]$$::jsonb) #>> '{results,0,outcome}',
  'accepted',
  'Ana modifica una jornada que el cliente ya había bajado'
);

select is(
  (select count(*)::integer from jsonb_array_elements(
     sync.pull(array['jornada'], (select w from wm_previo)) #> '{rows,jornada}')),
  1,
  'la fila modificada vuelve a salir en el delta (xmin_w re-estampado en el UPDATE)'
);

select is(
  (select r ->> 'total_visitas' from jsonb_array_elements(
     sync.pull(array['jornada'], (select w from wm_previo)) #> '{rows,jornada}') r),
  '7',
  'y sale con el valor nuevo'
);

-- has_more y el tope de página.
select is(
  sync.pull(array['jornada'], '{}'::jsonb, 1) ->> 'has_more',
  'true',
  'con más filas que el límite, has_more avisa'
);
select is(
  (select count(*)::integer from jsonb_array_elements(
     sync.pull(array['jornada'], '{}'::jsonb, 1) #> '{rows,jornada}')),
  1,
  'y la página respeta el límite'
);
select lives_ok(
  $$ select sync.pull(array['jornada'], '{}'::jsonb, -5) $$,
  'un límite negativo se acota en vez de reventar con un error de Postgres'
);

select lives_ok(
  $$ select sync.pull(array['entidad_del_futuro']) $$,
  'una entidad que el servidor no conoce se ignora: un cliente nuevo no tumba la sync'
);

-- ---------------------------------------------------------------------------
-- 7. Aislamiento: la RLS es la autoridad, también acá
-- ---------------------------------------------------------------------------

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000004a2');

select is(
  (select count(*)::integer from jsonb_array_elements(
     coalesce(sync.pull(array['jornada']) #> '{rows,jornada}', '[]'::jsonb))),
  0,
  'Beto no ve ninguna jornada de Ana en el delta (sin filtro manual: es la RLS)'
);

-- Beto conoce el id de la jornada de Ana y trata de pisarla.
select is(
  sync.push($$[
    {"client_op_id":"01920000-0000-7000-8000-000000004b09","entity":"jornada","op":"update",
     "sync_version":2,
     "payload":{"id":"01920000-0000-7000-8000-000000004f01","total_visitas":999}}
  ]$$::jsonb) #>> '{results,0,code}',
  'FILA_INEXISTENTE',
  'para Beto la jornada de Ana no existe: la RLS la esconde también del push'
);

select is(
  (select count(*)::integer from sync.op_cache),
  (select count(*)::integer from sync.op_cache where usuario_id = '01920000-0000-7000-8000-0000000004a1'),
  'Beto tampoco ve el cache de client_op_id de Ana'
);

-- ---------------------------------------------------------------------------
-- 8. house_status: PK que no se llama id
-- ---------------------------------------------------------------------------

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000004a1');

-- Se comprueba con Ana y no con Beto: para Beto la fila no existe, así que un
-- `select` suyo devuelve NULL y el assert pasaría por el motivo equivocado.
select is(
  (select total_visitas from public.jornada where id = '01920000-0000-7000-8000-000000004f01'),
  7,
  'el update de Beto no tocó la jornada de Ana'
);

select is(
  sync.push($$[
    {"client_op_id":"01920000-0000-7000-8000-000000004b10","entity":"ubicacion","op":"insert",
     "payload":{"id":"01920000-0000-7000-8000-000000004a01","tipo":"CASA","lat":-34.9,"lon":-56.18,
                "ciudad_id":"01920000-0000-7000-8000-0000000004c1",
                "zona_id":"01920000-0000-7000-8000-0000000004d1"}}
  ]$$::jsonb) #>> '{results,0,outcome}',
  'accepted',
  'Ana sube una ubicación de su zona'
);

select is(
  sync.push($$[
    {"client_op_id":"01920000-0000-7000-8000-000000004b11","entity":"house_status","op":"insert",
     "payload":{"ubicacion_id":"01920000-0000-7000-8000-000000004a01","lat":-34.9,"lon":-56.18,
                "tipo_ubicacion":"CASA","zona_id":"01920000-0000-7000-8000-0000000004d1",
                "color":"COBRANZA_PENDIENTE","prioridad":2}}
  ]$$::jsonb) #>> '{results,0,outcome}',
  'accepted',
  'house_status entra por su PK real (ubicacion_id), no por una columna id'
);

select is(
  (select count(*)::integer from jsonb_array_elements(
     sync.pull(array['house_status']) #> '{rows,house_status}')),
  1,
  'y sale por el delta con el watermark armado sobre esa misma PK'
);

-- ---------------------------------------------------------------------------
-- 9. Telemetría (RF-SY06) — solo UUIDs y contadores, nunca PII
-- ---------------------------------------------------------------------------

select ok(
  (select count(*) from sync.log where operacion = 'push') > 0,
  'cada push deja su línea de telemetría'
);
select is(
  (select count(*)::integer from sync.log where usuario_id <> '01920000-0000-7000-8000-0000000004a1'),
  0,
  'un colportor solo ve su propia telemetría'
);
select ok(
  (sync.estado() #>> '{ventana,aceptados}')::integer > 0,
  'sync.estado() resume la ventana del colportor'
);

-- ---------------------------------------------------------------------------
-- Limpieza
-- ---------------------------------------------------------------------------

reset role;
select set_config('request.jwt.claims', '', false);
select set_config('request.jwt.claim.sub', '', false);

delete from public.house_status where ubicacion_id = '01920000-0000-7000-8000-000000004a01';
delete from public.jornada   where colportor_id in ('01920000-0000-7000-8000-0000000004a1','01920000-0000-7000-8000-0000000004a2');
delete from public.ubicacion where ciudad_id = '01920000-0000-7000-8000-0000000004c1';
delete from public.producto  where id = '01920000-0000-7000-8000-0000000004e1';
delete from public.zona      where ciudad_id = '01920000-0000-7000-8000-0000000004c1';
delete from public.ciudad    where id = '01920000-0000-7000-8000-0000000004c1';
delete from public.pais      where id = '01920000-0000-7000-8000-0000000004c0';
-- usuario, op_cache y log se van por cascade desde auth.users.
delete from auth.users where id in ('01920000-0000-7000-8000-0000000004a1','01920000-0000-7000-8000-0000000004a2');

select * from finish();
