-- pgTAP · 0146 sobre los datos de antes: solo suma una columna calculada. Los tickets que ya había conservan todos sus
-- datos; los vivos reciben una vez la campaña que los valida (por la venta de su cobro o, sin cobro, por su fecha; nulo
-- = Administración) y su versión de sync sube para que los teléfonos la bajen; el dado de baja no se toca; los cobros
-- quedan idénticos. Ver scripts/db-test-migracion.sh y datos.sql.
begin;
select * from no_plan();

-- --- los datos de antes siguen ---------------------------------------------------------------
select is((select count(*)::int from public.ticket), 7, 'los siete tickets siguen');
select is((select count(*)::int from public.ticket t join public.prueba_0146_ticket s using (id)
            where (to_jsonb(t) - 'campania_validadora_id' - 'sync_version' - 'updated_at' - 'xmin_w')
                  is distinct from (to_jsonb(s) - 'sync_version' - 'updated_at' - 'xmin_w')), 0,
          'conservan todos sus datos de antes (cambian solo la columna nueva y la versión de sync)');
select is((select count(*)::int from public.cobranza c join public.prueba_0146_cobranza s using (id)
            where to_jsonb(c) is distinct from to_jsonb(s)), 0, 'los cobros, idénticos (ni la versión de sync)');

-- --- lo nuevo: quién valida cada ticket ----------------------------------------------------------
select is((select string_agg(format('%s=%s', right(id::text, 2), coalesce(right(campania_validadora_id::text, 2), '-')),
                             ',' order by id)
             from public.ticket),
          'a1=e1,a2=-,a3=-,a4=e1,a5=e1,a6=e1,a7=-',
          'a1 y a4 los valida e1 (por su fecha y por la venta del cobro); a2 y a3, Administración (a3: la venta no cae en ninguna campaña); los resueltos conservan e1; el dado de baja no se calculó');

-- --- los teléfonos se enteran -------------------------------------------------------------------
select is((select string_agg(right(t.id::text, 2), ',' order by t.id)
             from public.ticket t join public.prueba_0146_ticket s using (id)
            where t.sync_version > s.sync_version),
          'a1,a4,a5,a6',
          'sube la versión de sync de los que recibieron una campaña (los que no la tienen no cambian de valor)');
select is((select count(*)::int from public.ticket t join public.prueba_0146_ticket s using (id)
            where t.id = '01920000-0000-7000-8000-0000000146a7' and to_jsonb(t) - 'campania_validadora_id' is distinct from to_jsonb(s)), 0,
          'el ticket dado de baja quedó idéntico, versión de sync incluida');

-- --- sigue valiendo después ---------------------------------------------------------------------
select is((select columnas_servidor @> array['campania_validadora_id'] from sync.entidad where nombre = 'ticket'), true,
          'el push descarta la columna');
-- La coordinadora de e1 sigue viendo los tickets de e1 y no los de Administración.
select set_config('request.jwt.claims', json_build_object('sub', '01920000-0000-7000-8000-0000000146d1', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '01920000-0000-7000-8000-0000000146d1', true);
select set_config('role', 'authenticated', true);
select is((select string_agg(right(id::text, 2), ',' order by id) from public.ticket where campania_validadora_id is not null),
          'a1,a4,a5,a6', 'la coordinadora de la campaña ve los de su campaña');
select is((select string_agg(right(id::text, 2), ',' order by id) from public.ticket where campania_validadora_id is null), 'a7',
          'y entre los de campaña nula solo el dado de baja (a7, que por su fecha es de e1); a2 y a3 son de Administración y no los ve');

select * from finish();
rollback;
