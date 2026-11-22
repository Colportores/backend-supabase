-- ============================================================================
-- Suma a coordinador.demo como coordinador de las campañas de la demo generada (demo-datos.sql)
--
-- Por qué: el generador deja las dos campañas de la demo (Verano 2026-27 e Invierno 2026) a cargo de su propio
-- coordinador (demo.gustavo.ferreira, id 5eed0000-…), que no tiene contraseña. Quien entra al panel con la cuenta de
-- siempre (coordinador.demo@example.com) no coordina esas campañas y, por la RLS y campanias_del_coordinador(), no ve
-- ninguna de sus ventas, visitas, cobros ni depósitos: solo lo poco que cargó a mano en su propia campaña.
--
-- Qué hace: una fila en `campania_coordinador` por cada campaña viva de la demo (ids 5eed0000-0000-7000-8003-…) para
-- coordinador.demo. Una campaña admite varios coordinadores (0174): el coordinador generado sigue, y
-- `campania.coordinador_id` no cambia (es el vigente más antiguo, y esta fila es más nueva).
--
-- Reglas: solo agrega (INSERT … ON CONFLICT DO NOTHING); nunca DELETE, TRUNCATE ni cambios de esquema. Idempotente:
-- la segunda corrida no agrega nada. Si coordinador.demo no existe o no tiene el rol COORDINADOR (la base local, CI),
-- no hace nada. Se deshace con una baja lógica de esas filas, y retirar-demo-datos.sql ya las da de baja con el resto
-- de la demo (busca campania_coordinador por el prefijo de la campaña).
--
-- Cómo se corre: scripts/db-seed-demo.sh [--remoto] --coordinador (en remoto, solo ohdsavwpasfpapbyutrv).
-- ============================================================================

do $coordinador_demo$
declare
  v_coord    uuid;
  v_sumadas  integer;
begin
  select u.id into v_coord
    from public.usuario u
   where lower(u.email) = 'coordinador.demo@example.com'
     and u.deleted_at is null
     and exists (select 1
                   from public.usuario_rol ur
                   join public.rol r on r.id = ur.rol_id
                  where ur.usuario_id = u.id and ur.deleted_at is null and r.codigo = 'COORDINADOR');

  if v_coord is null then
    raise notice 'coordinador.demo no existe o no es coordinador en esta base: no se suma nada.';
    return;
  end if;

  -- clock_timestamp(): la fila queda después de la del coordinador generado aunque todo corra en una transacción, así el
  -- espejo (campania.coordinador_id = el vigente más antiguo) no cambia.
  insert into public.campania_coordinador (campania_id, usuario_id, created_at)
  select c.id, v_coord, clock_timestamp()
    from public.campania c
   where c.id::text like '5eed0000-0000-7000-8003-%'
     and c.deleted_at is null
  on conflict (campania_id, usuario_id) where deleted_at is null do nothing;
  get diagnostics v_sumadas = row_count;

  raise notice 'coordinador.demo sumado a % campaña(s) de la demo.', v_sumadas;
end
$coordinador_demo$;

-- Resultado (solo lectura): las campañas de la demo y si coordinador.demo las coordina.
select c.nombre as campania,
       exists (select 1
                 from public.campania_coordinador cc
                 join public.usuario u on u.id = cc.usuario_id
                where cc.campania_id = c.id and cc.deleted_at is null
                  and lower(u.email) = 'coordinador.demo@example.com') as coordinador_demo_la_coordina,
       (select count(*) from public.campania_coordinador cc where cc.campania_id = c.id and cc.deleted_at is null) as coordinadores
  from public.campania c
 where c.id::text like '5eed0000-0000-7000-8003-%'
   and c.deleted_at is null
 order by c.fecha_inicio desc;
