-- ============================================================================
-- 0051 · La unión baja al teléfono con la ubicación, y una casa unida no se reactiva
--        (backend-supabase#107; decisión de Cristian del 21/10, «Marca unión»)
--
-- Cambia la decisión del 16/10 (backend#69 P1) de que la unión quedara solo en la nube. El caso: la
-- colportora une B a A. En el teléfono, la marca «Unida a otra ubicación» de B vivía solo en el
-- teléfono que unió (un cruce por instante con el audit_log local) y se perdía con el primer pull de
-- `ubicacion` (el servidor reescribe `deleted_at`, 0026 paso 7 / 0035 paso 8) o en un teléfono nuevo:
-- B volvía a ser una baja común y se podía reactivar. Decisión: «El servidor la manda y la frena».
--
-- ## Qué hace
--
--   1. El pull de `ubicacion` (y el `server_row` de un conflicto) trae, en cada fila, la clave
--      `unida_a_id`: el id de la ubicación a la que se unió (`ubicacion_union.conservada_id`, 0035), o
--      `null` si no se unió. Solo el id. NO es una columna de `ubicacion`: se calcula al armar la fila
--      (`sync.expresion_json`), así `ubicacion_union` sigue siendo la única fuente y el teléfono no
--      puede escribirla (un push que la mande se ignora como cualquier clave que no es columna).
--      Es la ubicación a la que se unió en esa unión: si después esa se une a otra, la de B no cambia
--      (la cadena la sigue quien la necesite).
--   2. Para que la marca llegue por delta, registrar una unión «toca» a B (sube su `sync_version` y
--      su `xmin_w`). Casi siempre B ya se dio de baja en la misma operación y no hace falta; el caso
--      que lo necesita es la unión de una B que ya estaba de baja y sin nada colgado (una baja común o
--      una unión de 0026), que se registra sin tocarla. Las uniones ya registradas se tocan una vez en
--      esta migración, para que los teléfonos que ya bajaron a B reciban la marca.
--   3. Reactivar una B unida (deleted_at de no-null a null) se rechaza con el SQLSTATE `UB005` y el
--      texto «Esta ubicación se unió a otra y no se puede reactivar.»: por push, por RPC o por
--      PostgREST (un trigger). Una baja común se sigue reactivando igual. El push lo devuelve
--      `invalid` con `code` = `UB005`, sin tumbar el lote (sync.aplicar_job).
--
-- ## Permisos
--
--   · `ubicacion_union` sigue siendo de lectura exclusiva del ADMIN: nada de su política cambia.
--   · `public.ubicacion_unida_a(uuid)` es SECURITY DEFINER (lee el registro por quien llama) y devuelve
--     solo el id de la ubicación a la que se unió, o null. La llama el pull como el usuario, así que
--     authenticated tiene EXECUTE. Con un uuid de una ubicación que no ve devolvería su destino, pero
--     son ids v7 que no se adivinan y la fila no se lee por eso (la RLS de `ubicacion` sigue valiendo).
--   · Los triggers son SECURITY DEFINER y sin EXECUTE para nadie: corren igual.
--
-- ## Para otros repos
--
--   · front-colportores-mobile: la réplica guarda `unida_a_id` al aplicar el pull de `ubicacion`; la
--     leyenda «Unida a otra ubicación» y la guarda de «Reactivar» salen de ahí (`_unionDe` y
--     `observarListaDelColportor`), antes de conectar el pull en #178. El código nuevo `UB005`
--     (invalid) se traduce a «Esta ubicación se unió a otra y no se puede reactivar.».
--   · docs-organizacion (docs#72): contrato del sync (la clave y el código) y `esquema-datos.md`
--     («Registro de la unión»: la tabla sigue solo en la nube, pero su destino viaja en la fila).
--
-- Datos: las filas de B de las uniones ya registradas se actualizan sin cambiar ningún valor
-- (sube su versión de sync); nada se borra ni se pierde. Forward-only: no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. A qué ubicación se unió una ubicación
-- ----------------------------------------------------------------------------

create function public.ubicacion_unida_a(p_ubicacion_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select un.conservada_id
    from public.ubicacion_union un
   where un.duplicada_id = p_ubicacion_id;
$$;

comment on function public.ubicacion_unida_a(uuid) is
  'La ubicación a la que se unió la dada (ubicacion_union.conservada_id, 0035), o null si no se unió. '
  'La usa el pull para la clave unida_a_id de la fila de ubicacion (0051, backend-supabase#107). '
  'SECURITY DEFINER: ubicacion_union es del ADMIN; devuelve solo el id.';

-- `authenticated` va en el revoke por los default privileges de la imagen (ver 0008); el pull corre
-- como el usuario y la necesita.
revoke all on function public.ubicacion_unida_a(uuid) from public, anon, authenticated;
grant execute on function public.ubicacion_unida_a(uuid) to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 2. La clave en la fila de ubicacion (pull y server_row)
-- ----------------------------------------------------------------------------

-- Igual que en 0002, más la clave `unida_a_id` en la fila de `ubicacion`. El alias de la tabla es `t`
-- en todos los que la usan (pull, push). create or replace conserva privilegios.
create or replace function sync.expresion_json(p_tabla regclass)
returns text
language sql
stable
set search_path = ''
as $$
  select 'jsonb_build_object(' || string_agg(
           format('%L, %s', c.attname,
             case when c.atttypid = 'pg_catalog.numeric'::regtype
                  then format('(t.%I)::text', c.attname)
                  else format('t.%I', c.attname) end),
           ', ' order by c.attnum)
         || case when p_tabla = 'public.ubicacion'::regclass
                 then ', ''unida_a_id'', public.ubicacion_unida_a(t.id)'
                 else '' end
         || ')'
  from pg_catalog.pg_attribute c
  where c.attrelid = p_tabla
    and c.attnum > 0
    and not c.attisdropped
    and c.attname::text <> 'xmin_w';
$$;

comment on function sync.expresion_json(regclass) is
  'Serializa una fila a jsonb con los numeric como texto. Se usa con execute format(); los '
  'nombres salen del catálogo y pasan por %I, así que no hay inyección posible. La fila de ubicacion '
  'suma unida_a_id (0051): a qué ubicación se unió, o null; no es una columna.';

-- ----------------------------------------------------------------------------
-- 3. Registrar una unión toca a B, para que la marca baje por delta
-- ----------------------------------------------------------------------------

create function public.tg_ubicacion_union_avisa_al_telefono()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Sin cambiar ningún valor: tg_auditoria_update sube sync_version y xmin_w, y el delta la lleva. Si
  -- B ya se tocó en esta transacción (la unión la dio de baja) no hace falta tocarla de nuevo.
  update public.ubicacion u
     set updated_at = u.updated_at
   where u.id = new.duplicada_id
     and u.xmin_w is distinct from pg_current_xact_id();
  return null;
end;
$$;

comment on function public.tg_ubicacion_union_avisa_al_telefono() is
  'AFTER INSERT de ubicacion_union: toca a la duplicada para que su xmin_w avance y el pull lleve la '
  'marca unida_a_id (0051). Si ya se tocó en la misma transacción, no hace nada.';

create trigger ubicacion_union_avisa_al_telefono
  after insert on public.ubicacion_union
  for each row execute function public.tg_ubicacion_union_avisa_al_telefono();

-- Las uniones que ya estaban registradas: sus B vuelven a bajar una vez, con la marca.
update public.ubicacion u
   set updated_at = u.updated_at
  from public.ubicacion_union un
 where un.duplicada_id = u.id;

-- ----------------------------------------------------------------------------
-- 4. Una casa unida no se reactiva (UB005)
-- ----------------------------------------------------------------------------

create function public.tg_ubicacion_no_reactivar_unida()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.ubicacion_union un where un.duplicada_id = old.id) then
    raise exception using
      errcode = 'UB005',
      message = 'Esta ubicación se unió a otra y no se puede reactivar.';
  end if;
  return new;
end;
$$;

comment on function public.tg_ubicacion_no_reactivar_unida() is
  'BEFORE UPDATE OF deleted_at de ubicacion, al reactivar (de baja a viva): si es la duplicada de una '
  'unión (ubicacion_union), UB005. SECURITY DEFINER: lee el registro, que es del ADMIN (0051).';

-- El nombre corre antes que el resto de los BEFORE UPDATE (orden alfabético, 0021): el aviso propio
-- gana sobre un 42501 o un CG001.
create trigger ubicacion_a_no_reactivar_unida
  before update of deleted_at on public.ubicacion
  for each row
  when (old.deleted_at is not null and new.deleted_at is null)
  execute function public.tg_ubicacion_no_reactivar_unida();

-- Un trigger corre igual sin EXECUTE: ni siquiera authenticated.
revoke all on function
  public.tg_ubicacion_union_avisa_al_telefono(),
  public.tg_ubicacion_no_reactivar_unida()
  from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 5. El push: UB005 vuelve invalid, sin tumbar el lote
-- ----------------------------------------------------------------------------

-- Igual que en 0021, más UB005. Sus privilegios siguen (create or replace los conserva).
create or replace function sync.aplicar_job(p_job jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_id          uuid;
  v_restriccion text;
begin
  -- El cast va adentro del bloque protegido: un client_op_id malformado es un
  -- payload inválido, no un 500.
  begin
    v_id := (p_job ->> 'client_op_id')::uuid;
  exception when data_exception then
    v_id := null;
  end;

  return sync.aplicar_job_interno(v_id, p_job);
exception
  -- Clase 22, clase 23 y 42501: el payload está mal o la RLS rechazó la fila. INVALID, sin
  -- reintento automático, y sin tumbar al resto del lote (ver 0002).
  --
  -- Menos D1 (0017): misma dirección a menos de 100 m de otra ubicación viva. No es un payload
  -- roto: la fila es buena y la resuelve el colportor en la vista 10. Vuelve como conflicto, sin
  -- server_row (no hay fila del servidor que aplicar), y no entra al cache de client_op_id.
  when data_exception or integrity_constraint_violation or insufficient_privilege then
    get stacked diagnostics v_restriccion = constraint_name;
    if sqlstate = '23505' and v_restriccion = 'ubicacion_direccion_unica' then
      return jsonb_build_object(
        'client_op_id', v_id,
        'outcome', 'conflict',
        'code', sqlstate,
        'constraint', v_restriccion,
        'message', sqlerrm
      );
    end if;
    return jsonb_build_object(
      'client_op_id', v_id,
      'outcome', 'invalid',
      'code', sqlstate,
      'message', sqlerrm
    );
  -- La baja de una casa con ventas o con visitas de otro colportor (0018), la corrección ajena en la
  -- gracia (CG001, 0021) y reactivar una casa que se unió a otra (UB005, 0051): códigos propios, que
  -- la app traduce a un aviso. INVALID como el resto, sin tumbar el lote.
  when sqlstate 'UB001' or sqlstate 'UB002' or sqlstate 'CG001' or sqlstate 'UB005' then
    return jsonb_build_object(
      'client_op_id', v_id,
      'outcome', 'invalid',
      'code', sqlstate,
      'message', sqlerrm
    );
end;
$$;

-- ----------------------------------------------------------------------------
-- 6. Comentarios que quedaron viejos
-- ----------------------------------------------------------------------------

comment on table public.ubicacion_union is
  'Registro de «Marcar como duplicado» (0035, backend-supabase#69): B (duplicada_id) se unió a A '
  '(conservada_id). Idempotencia, cadena (si A se unió a C, B va a C) y redirección de lo que llega '
  'después nombrando a B. La tabla es solo de la nube (no está en sync.entidad) y la lee el ADMIN; el '
  'destino de B baja al teléfono como la clave unida_a_id de la fila de ubicacion (0051). Solo ids.';
