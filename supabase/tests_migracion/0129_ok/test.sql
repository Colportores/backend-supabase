-- pgTAP · 0129 sobre los datos de antes: solo suma. Los depósitos y los tickets que ya había quedan con todos
-- sus datos; el depósito de un ticket VALIDADO queda validado (con la fecha y el revisor del ticket) y es el único
-- que cambia (su versión de sync sube a propósito: el teléfono se entera); los demás nacen sin validar; la cuenta
-- no se toca; el alquiler que ya contaba como pagado sigue pagado; y la coordinadora valida un ticket de antes.
-- Ver scripts/db-test-migracion.sh y datos.sql.
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
select is((select count(*)::int from public.deposito), 5, 'los cinco depósitos siguen');
select is((select count(*)::int from public.deposito d join public.prueba_0129_deposito s using (id)
            where d.id <> '01920000-0000-7000-8000-000000012921'
              and to_jsonb(d) - 'validado_en' - 'validado_por' is distinct from to_jsonb(s)), 0,
          'los que no respaldaban un ticket validado quedaron idénticos en todas sus columnas de antes, sync_version y xmin_w incluidos');
select is((select count(*)::int from public.deposito d join public.prueba_0129_deposito s using (id)
            where d.id = '01920000-0000-7000-8000-000000012921'
              and (to_jsonb(d) - 'validado_en' - 'validado_por' - 'sync_version' - 'updated_at' - 'xmin_w')
                  is distinct from (to_jsonb(s) - 'sync_version' - 'updated_at' - 'xmin_w')), 0,
          'y el del ticket validado conserva todos sus datos (cambian solo la validación y la versión de sync)');
select is((select count(*)::int from public.ticket x join public.prueba_0129_ticket s using (id)
            where to_jsonb(x) is distinct from to_jsonb(s)), 0, 'los tickets, idénticos');
select is((select count(*)::int from public.cuenta_colportor x join public.prueba_0129_cuenta s using (id)
            where to_jsonb(x) is distinct from to_jsonb(s)), 0, 'la cuenta, idéntica');

-- --- lo nuevo -----------------------------------------------------------------------------------
select is((select (d.validado_en = t.revisado_en and d.validado_por = t.revisado_por)
             from public.deposito d join public.ticket t on t.id = d.ticket_id
            where d.id = '01920000-0000-7000-8000-000000012921'), true,
          'el depósito del ticket validado queda validado, con la fecha y el revisor del ticket');
select is((select d.sync_version > s.sync_version from public.deposito d join public.prueba_0129_deposito s using (id)
            where d.id = '01920000-0000-7000-8000-000000012921'), true,
          'su versión de sync subió: el teléfono se entera de que está validado');
select is((select count(*)::int from public.deposito where validado_en is not null), 1,
          'es el único validado: el del ticket pendiente, el del rechazado y el retiro sin ticket siguen por validar');

-- --- el alquiler que ya contaba como pagado sigue pagado ------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000129d1');
select is((select format('%s|%s|%s', c.alquiler_pagado, c.alquiler_por_validar, c.alquiler_debe)
             from public.cuentas_de_campania('01920000-0000-7000-8000-0000000129e1') c
            where c.colportor_id = '01920000-0000-7000-8000-0000000129b1'),
          '50000|50000|100000',
          'pagado 50000 (el validado), por validar 30000 (ticket pendiente) + 20000 (retiro sin ticket); el rechazado no cuenta');

-- --- la coordinadora valida un ticket de antes -----------------------------------------------------
select is((select format('%s|%s|%s|%s', v.estado, v.monto, v.deuda_antes, v.deuda_despues)
             from public.validar_ticket('01920000-0000-7000-8000-000000012914') v),
          'VALIDADO|70000|500000|430000', 'la coordinadora valida el depósito de casa editora de antes');
select pg_temp.actuar_como_servidor();
select is((select format('%s|%s', deuda_total, dinero_depositado) from public.cuenta_colportor
            where usuario_id = '01920000-0000-7000-8000-0000000129b1'), '430000|70000',
          'la deuda baja y Depositado sube');
select is((select validado_por from public.deposito where id = '01920000-0000-7000-8000-000000012925'),
          '01920000-0000-7000-8000-0000000129d1'::uuid, 'y el depósito queda validado por ella');

select * from finish();
rollback;
