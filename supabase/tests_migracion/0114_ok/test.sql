-- pgTAP · 0114 sobre los datos de antes: ningún depósito se pierde, los de ALQUILER sin campaña reciben la de su
-- inscripción (la vigente ese día o, si ninguna, la más nueva) y el de casa editora queda como estaba. Ver
-- scripts/db-test-migracion.sh y datos.sql.
begin;
select * from no_plan();

select is((select count(*)::int from public.deposito), 3, 'los 3 depósitos siguen');
select is((select count(*)::int from public.deposito where deleted_at is not null), 0, 'ninguno quedó dado de baja');
select is((select count(*)::int from public.deposito d join public.prueba_0114_deposito s using (id)
            where (d.colportor_id, d.monto, d.fecha, d.destino, d.concepto, d.ticket_id)
                  is distinct from (s.colportor_id, s.monto, s.fecha, s.destino, s.concepto, s.ticket_id)), 0,
          'monto, fecha, destino y concepto no cambian');
select is((select campania_id from public.deposito where id = '01920000-0000-7000-8000-0000000114f1'),
          '01920000-0000-7000-8000-0000000114c1'::uuid, 'f1: ALQUILER de b1: la campaña de su ventana (en curso)');
select is((select campania_id from public.deposito where id = '01920000-0000-7000-8000-0000000114f2'),
          '01920000-0000-7000-8000-0000000114c2'::uuid, 'f2: ALQUILER de b2 fuera de toda ventana: su inscripción más nueva');
select is((select campania_id from public.deposito where id = '01920000-0000-7000-8000-0000000114f3'),
          null::uuid, 'f3: CASA_EDITORA: sigue sin campaña');
select is((select count(*)::int from public.deposito where concepto = 'ALQUILER' and campania_id is null), 0,
          'ningún ALQUILER sin campaña');

select * from finish();
rollback;
