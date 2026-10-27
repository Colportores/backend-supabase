-- pgTAP · 0126 sobre los datos de antes: solo suma. Las transferencias y las líneas que ya había quedan idénticas
-- (con su versión de sync y su xmin_w: ni se enteran los teléfonos) salvo la rechazada cargada a mano sin motivo,
-- que recibe «Sin motivo registrado»; las columnas nuevas nacen vacías; el stock y la cuenta no se tocan; y la
-- coordinadora autoriza una de antes y el stock y la deuda pasan. Ver scripts/db-test-migracion.sh y datos.sql.
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

-- --- los datos de antes siguen ---------------------------------------------------------------
select is((select count(*)::int from public.transferencia_stock), 3, 'las tres transferencias siguen');
select is((select count(*)::int from public.transferencia_item), 3, 'y sus tres líneas');
select is((select count(*)::int
             from public.transferencia_stock t
             join public.prueba_0126_transferencia s using (id)
            where t.id <> '01920000-0000-7000-8000-000000012512'
              and to_jsonb(t) - 'monto_deuda' - 'decidido_en' - 'motivo_rechazo' is distinct from to_jsonb(s)), 0,
          'la que esperaba y la autorizada quedaron idénticas en todas sus columnas de antes, sync_version y xmin_w incluidos');
select is((select count(*)::int
             from public.transferencia_item i
             join public.prueba_0126_item s using (id)
            where to_jsonb(i) - 'precio_unitario' is distinct from to_jsonb(s)), 0,
          'las líneas, idénticas');
select is((select count(*)::int from public.stock x join public.prueba_0126_stock s using (id)
            where to_jsonb(x) is distinct from to_jsonb(s)), 0, 'el stock, idéntico');
select is((select count(*)::int from public.cuenta_colportor x join public.prueba_0126_cuenta s using (id)
            where to_jsonb(x) is distinct from to_jsonb(s)), 0, 'la cuenta, idéntica');

-- --- lo nuevo -----------------------------------------------------------------------------------
select is((select count(*)::int from public.transferencia_stock
            where monto_deuda is not null or decidido_en is not null), 0,
          'ninguna tiene deuda ni fecha de decisión: eso lo escribe autorizar o rechazar');
select is((select count(*)::int from public.transferencia_item where precio_unitario is not null), 0,
          'ni las líneas, costo guardado');
select is((select (estado, motivo_rechazo)::text from public.transferencia_stock
            where id = '01920000-0000-7000-8000-000000012512'),
          '(RECHAZADO,"Sin motivo registrado")', 'la rechazada sin motivo recibe uno, y no se borra ni cambia de estado');
select is((select motivo_rechazo from public.transferencia_stock where id = '01920000-0000-7000-8000-000000012511'),
          null::text, 'la que espera no tiene motivo');

-- --- la coordinadora autoriza una de antes --------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000125d1');
select is((select estado from public.autorizar_transferencia('01920000-0000-7000-8000-000000012511')), 'AUTORIZADO',
          'la coordinadora autoriza la que esperaba');
select pg_temp.actuar_como_servidor();
select is((select cantidad_disponible from public.stock
            where usuario_id = '01920000-0000-7000-8000-0000000125b1'), 3, 'quien da: 5 - 2');
select is((select cantidad_disponible from public.stock
            where usuario_id = '01920000-0000-7000-8000-0000000125b2'), 2, 'quien recibe: 2');
select is((select deuda_total from public.cuenta_colportor
            where usuario_id = '01920000-0000-7000-8000-0000000125b1'), 1000::bigint,
          'la deuda de quien da baja 2000 (2 libros a 1000)');
select is((select deuda_total from public.cuenta_colportor
            where usuario_id = '01920000-0000-7000-8000-0000000125b2'), 2000::bigint, 'y la de quien recibe sube 2000');
select is((select monto_deuda from public.transferencia_stock where id = '01920000-0000-7000-8000-000000012511'),
          2000::bigint, 'la transferencia guarda la deuda que pasó');

select * from finish();
rollback;
