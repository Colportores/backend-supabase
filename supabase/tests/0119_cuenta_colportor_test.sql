-- pgTAP · 0119 (backend-supabase#155, «Nombre cta.»): la tabla de plata del colportor se llama
-- `cuenta_colportor` y ya no `estado_cuenta`, que queda solo para la FUNCIÓN de HU-AUTH-008. Cubre:
--   1. El nombre: la tabla nueva existe, la vieja no, la función estado_cuenta() sigue y devuelve text.
--   2. Todo lo que cuelga de la tabla cambió de nombre con ella: constraints (y sus índices), triggers y política.
--   3. Lo que no cambia: RLS prendida, la misma columna de plata, los mismos privilegios.
--   4. Nada de public lee la tabla con el nombre viejo (funciones, vistas, políticas): lo rompe cualquier
--      migración posterior que la nombre mal.
-- El resto del issue (deposito.campania_id obligatoria para ALQUILER y los saldos separados por campaña) lo
-- prueba 0114.
begin;
select * from no_plan();

-- --- 1. El nombre ----------------------------------------------------------------
select has_table('public', 'cuenta_colportor', 'la tabla de plata del colportor se llama cuenta_colportor');
select hasnt_table('public', 'estado_cuenta', 'y ya no existe una tabla estado_cuenta');
select has_function('public', 'estado_cuenta', array[]::text[], 'la función estado_cuenta() de HU-AUTH-008 sigue');
select function_returns('public', 'estado_cuenta', array[]::text[], 'text', 'y sigue devolviendo el estado de la cuenta de usuario');
select is((select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relname like '%estado_cuenta%'), 0,
          'ninguna tabla, índice ni secuencia de public se llama estado_cuenta');

-- --- 2. Lo que cuelga de la tabla ---------------------------------------------------
select is((select array(select conname::text from pg_constraint
                          where conrelid = 'public.cuenta_colportor'::regclass order by conname)),
          array['cuenta_colportor_created_by_fkey', 'cuenta_colportor_pkey',
                'cuenta_colportor_usuario_id_fkey', 'cuenta_colportor_usuario_key'],
          'los cuatro constraints llevan el nombre nuevo (clave, único por usuario y las dos FK)');
select is((select array(select indexname::text from pg_indexes
                         where schemaname = 'public' and tablename = 'cuenta_colportor' order by indexname)),
          array['cuenta_colportor_pkey', 'cuenta_colportor_usuario_key'],
          'y los índices que los respaldan');
select is((select array(select tgname::text from pg_trigger
                          where tgrelid = 'public.cuenta_colportor'::regclass and not tgisinternal order by tgname)),
          array['cuenta_colportor_auditoria_insert', 'cuenta_colportor_auditoria_update'],
          'los dos triggers de auditoría llevan el nombre nuevo');
select is((select array(select policyname::text from pg_policies
                         where schemaname = 'public' and tablename = 'cuenta_colportor' order by policyname)),
          array['cuenta_colportor_select'],
          'la política de lectura lleva el nombre nuevo y sigue siendo la única');
select is((select array(select cmd::text from pg_policies
                         where schemaname = 'public' and tablename = 'cuenta_colportor')),
          array['SELECT'], 'y sigue siendo solo de lectura (nadie con JWT escribe)');
select ok((select obj_description('public.cuenta_colportor'::regclass, 'pg_class') like '%estado_cuenta()%'),
          'el comentario de la tabla explica la diferencia con la función estado_cuenta()');

-- --- 3. Lo que no cambia ---------------------------------------------------------------
select is((select relrowsecurity from pg_class where oid = 'public.cuenta_colportor'::regclass), true,
          'la RLS sigue prendida');
select columns_are('public', 'cuenta_colportor',
  array['id', 'usuario_id', 'deuda_total', 'dinero_depositado', 'dinero_en_mano', 'dinero_por_cobrar',
        'deuda_alquiler', 'actualizado_en', 'created_at', 'updated_at', 'created_by', 'deleted_at',
        'sync_version', 'xmin_w'],
  'las columnas son las de siempre');
select ok(has_table_privilege('authenticated', 'public.cuenta_colportor', 'select'),
          'authenticated sigue leyendo (la RLS recorta a lo suyo)');
select ok(not has_table_privilege('authenticated', 'public.cuenta_colportor', 'insert')
      and not has_table_privilege('authenticated', 'public.cuenta_colportor', 'update')
      and not has_table_privilege('authenticated', 'public.cuenta_colportor', 'delete'),
          'y sigue sin escribir');
select ok(not has_table_privilege('anon', 'public.cuenta_colportor', 'select'), 'anon no lee nada');
select ok(has_table_privilege('service_role', 'public.cuenta_colportor', 'select,insert,update,delete'),
          'service_role sigue con todo');

-- --- 4. Nadie lo lee con el nombre viejo -------------------------------------------------
-- Cualquier función de public cuyo cuerpo mencione la tabla vieja (no la función estado_cuenta()). Si un PR
-- que todavía no mergeó (0112: mover_deuda_casa_editora, pedido_contexto) llega con el nombre viejo, este
-- test lo muestra.
select is((select coalesce(string_agg(p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')', ', ' order by p.proname), '')
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.prosrc ~ 'estado_cuenta(?![_(a-z])'
              and p.prosrc ~ '(from|join|into|update|table)\s+(public\.)?estado_cuenta(?![_(a-z])'),
          '', 'ninguna función de public lee ni escribe la tabla con el nombre viejo');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = 'cuentas_de_campania' and p.prosrc like '%cuenta_colportor%'), 1,
          'cuentas_de_campania() lee la tabla con el nombre nuevo');
select is((select count(*)::int from pg_views where schemaname = 'public' and definition ~ 'estado_cuenta(?![_(a-z])'), 0,
          'ninguna vista de public menciona la tabla vieja');

select * from finish();
rollback;
