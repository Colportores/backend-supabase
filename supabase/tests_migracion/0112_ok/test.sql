-- pgTAP · 0112 sobre los datos de antes: solo suma. Los pedidos y sus líneas quedan idénticos en todo lo
-- que ya tenían (con su versión de sync y su xmin_w; el rechazado de antes recibe un motivo), las columnas nuevas nacen en null y el pedido de antes
-- por autorizar se puede autorizar y deshacer. Ver scripts/db-test-migracion.sh y datos.sql.
begin;
select * from no_plan();

-- --- los datos de antes siguen --------------------------------------------------------------
select is((select count(*)::int from public.pedido_casa_editora), 4, 'los 4 pedidos siguen');
select is((select count(*)::int from public.pedido_casa_editora p join public.prueba_0112_pedido s using (id)
            where to_jsonb(p) - 'monto_autorizado' - 'decidido_por' - 'decidido_en' - 'motivo_rechazo' - 'numero'
                  is distinct from to_jsonb(s)
              and p.id <> '01920000-0000-7000-8000-000000011204'), 0,
          'idénticos en todo lo que ya tenían, sync_version y xmin_w incluidos (salvo el rechazado de antes, al que se le puso el motivo)');
select is((select sync_version from public.pedido_casa_editora where id = '01920000-0000-7000-8000-000000011203'),
          1::bigint, 'el corregido conserva su versión de sync');
select is((select count(*)::int from public.pedido_item i join public.prueba_0112_pedido_item s using (id)
            where to_jsonb(i) - 'cantidad_autorizada' is distinct from to_jsonb(s)), 0,
          'las 4 líneas, idénticas');

-- --- las columnas nuevas nacen en null -------------------------------------------------------
select is((select count(*)::int from public.pedido_casa_editora
            where monto_autorizado is not null or decidido_por is not null
               or decidido_en is not null
               or (motivo_rechazo is not null and estado <> 'RECHAZADO')), 0,
          'ningún pedido de antes tiene monto autorizado, decisión ni motivo');
select is((select motivo_rechazo from public.pedido_casa_editora where id = '01920000-0000-7000-8000-000000011204'),
          'Sin motivo registrado', 'el rechazado de antes recibe un motivo (la regla nueva lo exige) y sigue ahí');
select is((select count(*)::int from public.pedido_item where cantidad_autorizada is not null), 0,
          'ninguna línea de antes tiene cantidad autorizada (null = se autorizó lo pedido)');

-- --- el pedido de antes entra en el flujo nuevo -------------------------------------------------
create or replace function pg_temp.actuar_como(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('role', 'authenticated', true);
end $$;

-- Un administrador (sin JWT de colportor): ADMIN decide cualquier pedido.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
values ('01920000-0000-7000-8000-0000000112a1', '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated', 'migracion112-admin@example.com', 'x', now(), now(), now());
insert into public.usuario_rol (usuario_id, rol_id)
select '01920000-0000-7000-8000-0000000112a1', r.id from public.rol r where r.codigo = 'ADMIN';

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000112a1');

select is((select monto_autorizado from public.autorizar_pedido('01920000-0000-7000-8000-000000011201')),
          500000::bigint, 'el pedido de antes se autoriza por lo que pidió');
select is((select deuda_total from public.cuenta_colportor where usuario_id = '01920000-0000-7000-8000-0000000112b1'),
          500000::bigint, 'y suma su deuda');
select is((select estado from public.deshacer_decision_de_pedido('01920000-0000-7000-8000-000000011201')),
          'PENDIENTE_AUTORIZACION', 'y se deshace dentro del plazo');
select is((select deuda_total from public.cuenta_colportor where usuario_id = '01920000-0000-7000-8000-0000000112b1'),
          0::bigint, 'la deuda vuelve a donde estaba');

select * from finish();
rollback;
