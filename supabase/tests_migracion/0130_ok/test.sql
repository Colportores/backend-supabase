-- pgTAP · 0130 sobre los datos de antes: numera los pedidos que ya había por fecha de pedido y no toca nada más
-- (la versión de sync y el xmin_w quedan iguales). Los nuevos siguen la secuencia, sin repetir. Ver
-- scripts/db-test-migracion.sh y datos.sql.
begin;
select * from no_plan();

select is((select count(*)::int from public.pedido_casa_editora), 4, 'los cuatro pedidos siguen');
select is((select string_agg(right(id::text, 2) || '=' || numero, ',' order by numero) from public.pedido_casa_editora),
          '03=1,04=2,02=3,01=4', 'se numeran por fecha de pedido: el más viejo es el 1');
select is((select count(*)::int
             from public.pedido_casa_editora p
             join public.prueba_0130_pedido s using (id)
            where to_jsonb(p) - 'numero' is distinct from to_jsonb(s)), 0,
          'idénticos en todas sus columnas de antes, sync_version y xmin_w incluidos');
select is((select sync_version from public.pedido_casa_editora where id = '01920000-0000-7000-8000-000000013003'),
          1::bigint, 'el corregido conserva su versión de sync');
select is((select count(*)::int from public.pedido_casa_editora where numero is null), 0, 'ninguno quedó sin número');

-- La secuencia sigue después de la última, y el default sirve para una fila nueva.
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, origen)
values ('01920000-0000-7000-8000-000000013005', '01920000-0000-7000-8000-0000000130b2',
        'PENDIENTE_AUTORIZACION', 0, 'COLPORTOR');
select is((select numero from public.pedido_casa_editora where id = '01920000-0000-7000-8000-000000013005'), 5::bigint,
          'el próximo pedido es el 5');

-- Un pedido dado de baja no devuelve su número.
update public.pedido_casa_editora set deleted_at = now() where id = '01920000-0000-7000-8000-000000013005';
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, origen)
values ('01920000-0000-7000-8000-000000013006', '01920000-0000-7000-8000-0000000130b2',
        'PENDIENTE_AUTORIZACION', 0, 'COLPORTOR');
select is((select numero from public.pedido_casa_editora where id = '01920000-0000-7000-8000-000000013006'), 6::bigint,
          'y el que sigue es el 6: el 5 no se reutiliza');

-- El número es del servidor: pull y push lo tratan como tal.
select is((select columnas_servidor @> array['numero'] from sync.entidad where nombre = 'pedido_casa_editora'), true,
          'numero está en columnas_servidor');

select * from finish();
rollback;
