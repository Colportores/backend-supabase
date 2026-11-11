-- pgTAP · 0124 sobre los datos de antes: solo suma. Los pedidos que ya había quedan idénticos (con su versión de
-- sync y su xmin_w: ni se enteran los teléfonos); las líneas también, salvo la dueña, que se completa desde el
-- pedido; las entidades de antes quedan idénticas y las únicas nuevas son pedido_casa_editora y pedido_item; y
-- la colportora puede mandar un pedido nuevo con su línea. Ver scripts/db-test-migracion.sh y datos.sql.
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
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;

-- --- los datos de antes siguen ---------------------------------------------------------------
select is((select count(*)::int from public.pedido_casa_editora), 2, 'los dos pedidos siguen');
select is((select count(*)::int from public.pedido_casa_editora p join public.prueba_0124_pedido s using (id)
            where to_jsonb(p) is distinct from to_jsonb(s)), 0,
          'quedaron idénticos en todas sus columnas, sync_version y xmin_w incluidos: ni se enteran los teléfonos');
select is((select count(*)::int from public.pedido_item), 2, 'las dos líneas siguen');
select is((select count(*)::int from public.pedido_item i join public.prueba_0124_item s using (id)
            where to_jsonb(i) - 'colportor_id' is distinct from to_jsonb(s)), 0,
          'idénticas salvo la dueña (también su versión y su xmin_w)');
select is((select count(*)::int from public.pedido_item i join public.pedido_casa_editora p on p.id = i.pedido_id
            where i.colportor_id = p.colportor_id), 2, 'y cada línea tomó la dueña de su pedido');

-- --- el registro de sync -----------------------------------------------------------------------
select is((select count(*)::int
             from sync.entidad e
             join public.prueba_0124_entidad s using (nombre)
            where (e.tabla::text, e.columna_pk, e.permite_push, e.columnas_servidor, e.sigue_campanias, e.columna_duenio)
                  is distinct from (s.tabla, s.columna_pk, s.permite_push, s.columnas_servidor, s.sigue_campanias, s.columna_duenio)), 0,
          'las entidades de antes quedaron idénticas');
select is((select array_agg(nombre order by nombre) from sync.entidad e
            where not exists (select 1 from public.prueba_0124_entidad s where s.nombre = e.nombre)),
          array['pedido_casa_editora', 'pedido_item'], 'y las únicas nuevas son pedido_casa_editora y pedido_item');

-- --- la colportora manda un pedido nuevo --------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000123b1');
select lives_ok($$ insert into public.pedido_casa_editora (id, estado)
                   values ('01920000-0000-7000-8000-0000000123f3', 'PENDIENTE_AUTORIZACION') $$,
                'la colportora manda un pedido nuevo');
select lives_ok($$ insert into public.pedido_item (id, pedido_id, producto_id, cantidad)
                   values ('01920000-0000-7000-8000-0000000123c3', '01920000-0000-7000-8000-0000000123f3',
                           '01920000-0000-7000-8000-0000000123a1', 11) $$,
                'con su línea');
select pg_temp.actuar_como_servidor();
select is((select monto_total::text || '/' || excede_limite::text || '/' || origen from public.pedido_casa_editora
            where id = '01920000-0000-7000-8000-0000000123f3'), '11000/true/COLPORTOR',
          'el servidor calcula el monto (11 × 1000) y avisa que supera el límite de 10000');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000123b1');
select is(pg_temp.error_de($$ insert into public.pedido_item (id, pedido_id, producto_id, cantidad)
                              values ('01920000-0000-7000-8000-0000000123c4', '01920000-0000-7000-8000-0000000123f1',
                                      '01920000-0000-7000-8000-0000000123a1', 1) $$),
          '23514', 'y no le suma líneas al pedido de antes, ya autorizado');
select is(pg_temp.error_de($$ update public.pedido_casa_editora set estado = 'CANCELADO'
                              where id = '01920000-0000-7000-8000-0000000123f1' $$),
          '42501', 'ni lo cancela');
select is(pg_temp.error_de($$ update public.pedido_casa_editora set estado = 'CANCELADO'
                              where id = '01920000-0000-7000-8000-0000000123f2' $$),
          'ok', 'pero sí cancela el que estaba por autorizar');
select pg_temp.actuar_como_servidor();
select is((select count(*)::int from public.pedido_casa_editora p join public.prueba_0124_pedido s using (id)
            where p.id = '01920000-0000-7000-8000-0000000123f1' and to_jsonb(p) is distinct from to_jsonb(s)), 0,
          'el pedido autorizado de antes sigue intacto');

select * from finish();
rollback;
