-- pgTAP · 0120 sobre los datos de antes: ninguna campaña ni inscripción se pierde (la dada de baja tampoco), el
-- límite de pedido por inscripción desaparece sin tocar ninguna otra columna ni la versión de sync, la campaña
-- arranca sin límite y lo nuevo anda sobre esos datos: la coordinadora fija el límite de su campaña y el pedido de
-- b1 se mide contra él. Ver scripts/db-test-migracion.sh y datos.sql.
begin;
select * from no_plan();

select is((select count(*)::int from public.campania where id::text like '01920000-0000-7000-8000-0000000120%'), 2,
          'las 2 campañas siguen');
select is((select count(*)::int from public.campania_colportor where id::text like '01920000-0000-7000-8000-0000000120%'), 3,
          'las 3 inscripciones siguen, la dada de baja también');
select is((select deleted_at is not null from public.campania_colportor where id = '01920000-0000-7000-8000-0000000120e3'), true,
          'y la inscripción dada de baja sigue de baja');

-- La columna vieja se fue y la nueva arranca en null: es la única diferencia con la foto.
select hasnt_column('public', 'campania_colportor', 'limite_pedido', 'la inscripción ya no trae limite_pedido');
select is((select count(*)::int from public.campania where limite_deuda is not null), 0,
          'ninguna campaña tiene límite hasta que alguien lo cargue: los de por colportor no se convierten');
select is((select count(*)::int from public.campania c join public.prueba_0120_campania s using (id)
            where to_jsonb(c) - 'limite_deuda' is distinct from to_jsonb(s)), 0,
          'las 2 campañas quedaron idénticas (versión de sync, updated_at y xmin_w incluidos) salvo la columna nueva');
select is((select count(*)::int from public.campania_colportor c join public.prueba_0120_campania_colportor s using (id)
            where to_jsonb(c) is distinct from to_jsonb(s) - 'limite_pedido'), 0,
          'las 3 inscripciones quedaron idénticas (meta_libros, baja, versión de sync y xmin_w incluidos) salvo el límite que se fue');
select is((select meta_libros from public.campania_colportor where id = '01920000-0000-7000-8000-0000000120e1'), 120,
          'la meta de libros de antes sigue');
select is((select count(*)::int from public.cuenta_colportor c join public.prueba_0120_cuenta s using (id)
            where to_jsonb(c) is distinct from to_jsonb(s)), 0, 'la cuenta de b1 quedó idéntica');

-- Lo nuevo anda sobre los datos de antes: la coordinadora fija el límite de su campaña.
select set_config('request.jwt.claims',
                  json_build_object('sub', '01920000-0000-7000-8000-0000000120d1', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '01920000-0000-7000-8000-0000000120d1', true);
select set_config('role', 'authenticated', true);
select is((select format('%s|%s', r.limite_deuda, r.cambio)
             from public.definir_limite_de_deuda_de_campania('01920000-0000-7000-8000-0000000120c1', 2000000) r),
          '2000000|t', 'la coordinadora de la campaña de antes fija su límite de deuda');
select throws_ok($$ select * from public.definir_limite_de_deuda_de_campania('01920000-0000-7000-8000-0000000120c2', 2000000) $$,
  'CZ011', null, 'la campaña que terminó no lo cambia');
select set_config('role', 'postgres', true);
select is((select limite_deuda from public.campania where id = '01920000-0000-7000-8000-0000000120c1'), 2000000::bigint, 'y queda');

-- b1 debe 1.800.000: un pedido de 200.000 llega justo; uno de 200.001 lo supera por 1.
select is(public.supera_limite_de_deuda_por('01920000-0000-7000-8000-0000000120b1', '01920000-0000-7000-8000-0000000120c1', 200000),
          null::bigint, 'el pedido de b1 que llega justo al límite no lo supera');
select is(public.supera_limite_de_deuda_por('01920000-0000-7000-8000-0000000120b1', '01920000-0000-7000-8000-0000000120c1', 200001),
          1::bigint, 'y con un centavo más lo supera por 1');
select is(public.pedido_excede_limite_de_deuda('01920000-0000-7000-8000-0000000120b2', '01920000-0000-7000-8000-0000000120c1', 2000000),
          false, 'b2, sin cuenta, llega justo con un pedido igual al límite');
select is(public.pedido_excede_limite_de_deuda('01920000-0000-7000-8000-0000000120b2', '01920000-0000-7000-8000-0000000120c2', 99999999),
          false, 'en la campaña que terminó, sin límite, nada excede');

select * from finish();
rollback;
