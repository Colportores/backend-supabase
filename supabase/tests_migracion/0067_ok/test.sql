-- pgTAP · 0067 suma campania.alquiler_monto y campania_colportor.tipo_beca / meta_monto_ces / limite_pedido
-- en null a lo que ya había, y crea las nueve tablas de stock y cuenta vacías. No toca ninguna fila: ni
-- sus columnas, ni sync_version, ni xmin_w. Ver scripts/db-test-migracion.sh y datos.sql.
begin;
select * from no_plan();

select is((select count(*)::int from public.campania where id::text like '01920000-0000-7000-8000-0000000067%'), 2,
          'las 2 campañas siguen: no se perdió ninguna');
select is((select count(*)::int from public.campania_colportor where id::text like '01920000-0000-7000-8000-0000000067%'), 3,
          'las 3 inscripciones siguen, la dada de baja también');

-- Las columnas nuevas arrancan en null y es la única diferencia con la foto.
select is((select count(*)::int from public.campania where alquiler_monto is not null), 0,
          'ninguna campaña cobra alquiler hasta que alguien lo cargue');
select is((select count(*)::int from public.campania c join public.prueba_0067_campania s using (id)
            where to_jsonb(c) - 'alquiler_monto' is distinct from to_jsonb(s)), 0,
          'las 2 campañas quedaron idénticas (versión de sync, updated_at y xmin_w incluidos) salvo la columna nueva');
select is((select count(*)::int from public.campania_colportor
            where tipo_beca is not null or meta_monto_ces is not null or limite_pedido is not null), 0,
          'ninguna inscripción trae beca, meta de monto ni límite: sin beca y sin límite');
select is((select count(*)::int from public.campania_colportor c join public.prueba_0067_campania_colportor s using (id)
            where to_jsonb(c) - 'tipo_beca' - 'meta_monto_ces' - 'limite_pedido' - 'tramos_afuera' is distinct from to_jsonb(s)), 0,
          'las 3 inscripciones quedaron idénticas (meta_libros, baja, versión de sync y xmin_w incluidos) salvo las columnas nuevas');
select is((select meta_libros from public.campania_colportor where id = '01920000-0000-7000-8000-0000000067c1'), 120,
          'la meta de libros de antes sigue');
select is((select deleted_at is not null from public.campania_colportor where id = '01920000-0000-7000-8000-0000000067c3'), true,
          'y la inscripción dada de baja sigue de baja');

-- Las tablas nuevas existen y están vacías.
select is((select count(*)::int from public.stock) + (select count(*)::int from public.pedido_casa_editora)
        + (select count(*)::int from public.pedido_item) + (select count(*)::int from public.movimiento_stock)
        + (select count(*)::int from public.transferencia_stock) + (select count(*)::int from public.transferencia_item)
        + (select count(*)::int from public.deposito) + (select count(*)::int from public.ticket)
        + (select count(*)::int from public.estado_cuenta), 0,
          'las nueve tablas nuevas arrancan vacías: no se inventa ningún saldo ni ningún stock');

-- Lo nuevo anda sobre los datos de antes: el servidor fija la beca y el coordinador de esa campaña el límite.
update public.campania set alquiler_monto = 150000 where id = '01920000-0000-7000-8000-0000000067e1';
update public.campania_colportor set tipo_beca = 'MEDIA', meta_monto_ces = 3000000
 where id = '01920000-0000-7000-8000-0000000067c1';
select set_config('request.jwt.claims',
                  json_build_object('sub', '01920000-0000-7000-8000-0000000067a1', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '01920000-0000-7000-8000-0000000067a1', true);
select set_config('role', 'authenticated', true);
select lives_ok($$ update public.campania_colportor set limite_pedido = 2000000
                    where id = '01920000-0000-7000-8000-0000000067c1' $$,
                'el coordinador de la campaña fija el límite de una inscripción de antes');
select set_config('role', 'postgres', true);
select is((select limite_pedido from public.campania_colportor where id = '01920000-0000-7000-8000-0000000067c1'), 2000000::bigint,
          'y queda');

select * from finish();
rollback;
