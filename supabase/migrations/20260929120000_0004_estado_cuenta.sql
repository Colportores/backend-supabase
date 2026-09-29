-- ============================================================================
-- 0004 · Estado de la cuenta del usuario (HU-AUTH-008)
--
-- Decisión de Cristian (front-colportores-mobile#62, opción b): el estado NO es una
-- columna que alguien tenga que mantener.
--
--   · PENDIENTE_ASIGNACION se DERIVA de campania_colportor: la cuenta está pendiente si
--     no tiene una inscripción vigente (fila no borrada, campaña no borrada y hoy entre
--     fecha_inicio y fecha_fin). Cuando HU-CAM-004 inscribe al colportor, la cuenta queda
--     ACTIVA sola: no hay un segundo dato que actualizar ni que se pueda desincronizar.
--   · SUSPENDIDA es una marca aparte: usuario.suspendido_en (null = no suspendido).
--     Gana sobre todo lo demás: una cuenta suspendida con campaña vigente sigue suspendida.
--
-- La vigencia de una inscripción es el mismo criterio que ya usaba mis_zonas(). Se
-- factoriza en mis_campanias_vigentes() y mis_zonas() pasa a usarla, para que "vigente"
-- quede escrito en un solo lugar. Diferencia a propósito: mis_zonas() descarta las
-- inscripciones sin zona (no abren ninguna zona); el estado de la cuenta las cuenta
-- (estar inscripto en la campaña es lo que activa la cuenta, tenga zona o todavía no).
--
-- Lo que NO está acá:
--   · Quién suspende y reactiva (rol, motivo, auditoría, revocar sesiones): HU-ADM-003,
--     sin decidir para este esquema. Mientras tanto la marca es server-authoritative:
--     ningún JWT la cambia (sección 2). Sin esa guarda, usuario_update_propio le dejaba
--     a un colportor suspendido levantarse la suspensión con un UPDATE de su propia fila.
--   · El endpoint GET /v1/me de bff-colportores (ADR-013) y el data source de la app.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Marca de suspensión
-- ----------------------------------------------------------------------------

alter table public.usuario add column suspendido_en timestamptz;

comment on column public.usuario.suspendido_en is
  'Desde cuándo la cuenta está suspendida (HU-ADM-003). null = no suspendida. '
  'estado_cuenta() devuelve SUSPENDIDA si no es null, tenga o no campaña vigente.';

-- ----------------------------------------------------------------------------
-- 2. Guarda de columna: la suspensión la fija el servidor
-- ----------------------------------------------------------------------------

-- Regla 6 del 0001: lo que la RLS no alcanza por ser a nivel fila se cierra con triggers.
-- usuario_update_propio deja que cada usuario actualice su fila entera; sin esto, la
-- suspensión se levanta con un PATCH de la propia fila.
--
-- Quién puede suspender con su JWT (ADMIN, coordinador, nadie) es de HU-ADM-003 y no
-- está decidido: hasta entonces solo la cambia un proceso servidor (auth.uid() null:
-- service_role, migraciones, seeds, jobs). Se coerciona al valor viejo en silencio, igual
-- que tg_usuario_zona_servidor(): un cliente que manda la fila entera con un valor viejo
-- de la marca no tiene por qué fallar, pero tampoco ganar.
create function public.tg_usuario_suspension_servidor()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.suspendido_en is distinct from old.suspendido_en
     and auth.uid() is not null then
    new.suspendido_en := old.suspendido_en;
  end if;
  return new;
end;
$$;

create trigger usuario_suspension_servidor
  before update on public.usuario
  for each row execute function public.tg_usuario_suspension_servidor();

-- ----------------------------------------------------------------------------
-- 3. Inscripciones vigentes del usuario autenticado (factorizado de mis_zonas)
-- ----------------------------------------------------------------------------

-- SECURITY DEFINER y search_path vacío, igual que mis_zonas() y tiene_rol(): es un helper
-- que usan las políticas RLS (vía mis_zonas) y no puede depender de la RLS que ayuda a
-- evaluar. No recibe el usuario: sale de auth.uid(), así que nadie consulta las ajenas.
create function public.mis_campanias_vigentes()
returns table (campania_id uuid, zona_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select cc.campania_id, cc.zona_id
    from public.campania_colportor cc
    join public.usuario u on u.id = cc.usuario_id
    join public.campania c on c.id = cc.campania_id
   where cc.usuario_id = auth.uid()
     and cc.deleted_at is null
     and u.deleted_at is null
     and c.deleted_at is null
     and c.fecha_inicio <= current_date
     and (c.fecha_fin is null or c.fecha_fin >= current_date);
$$;

comment on function public.mis_campanias_vigentes() is
  'Inscripciones vigentes hoy del usuario autenticado (campania_colportor no borrada, campaña '
  'no borrada, hoy entre fecha_inicio y fecha_fin). Única definición de "vigente": la usan '
  'mis_zonas() y estado_cuenta().';

-- Misma firma, mismo resultado: la rama de campañas lee la vigencia del helper. Lo
-- verifican 0002_rls_test y 0004_sync_delta_test (aislamiento por zona) y 0006.
create or replace function public.mis_zonas()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select u.zona_id from public.usuario u
   where u.id = auth.uid() and u.zona_id is not null and u.deleted_at is null
  union
  select v.zona_id from public.mis_campanias_vigentes() v
   where v.zona_id is not null;
$$;

-- ----------------------------------------------------------------------------
-- 4. estado_cuenta() — el RPC que consume bff-colportores (GET /v1/me)
-- ----------------------------------------------------------------------------

-- SECURITY INVOKER, como los RPC de sync: lee la fila propia de usuario con la RLS del
-- llamador (usuario_select_propio_o_staff), así que no hay privilegio que escalar. No
-- recibe el usuario por parámetro: el estado ajeno no se puede pedir.
create function public.estado_cuenta()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_suspendido_en timestamptz;
begin
  if auth.uid() is null then
    raise exception 'estado_cuenta requiere un usuario autenticado'
      using errcode = 'insufficient_privilege';
  end if;

  select u.suspendido_en into v_suspendido_en
    from public.usuario u
   where u.id = auth.uid();

  if not found then
    raise exception 'el usuario autenticado no tiene perfil en public.usuario'
      using errcode = 'no_data_found';
  end if;

  if v_suspendido_en is not null then
    return 'SUSPENDIDA';
  elsif exists (select 1 from public.mis_campanias_vigentes()) then
    return 'ACTIVA';
  else
    return 'PENDIENTE_ASIGNACION';
  end if;
end;
$$;

comment on function public.estado_cuenta() is
  'Estado de la cuenta del usuario autenticado (HU-AUTH-008): ACTIVA | PENDIENTE_ASIGNACION | '
  'SUSPENDIDA. Derivado: SUSPENDIDA si usuario.suspendido_en no es null; si no, ACTIVA si '
  'tiene una inscripción vigente (mis_campanias_vigentes()); si no, PENDIENTE_ASIGNACION.';

-- ----------------------------------------------------------------------------
-- 5. Privilegios
-- ----------------------------------------------------------------------------

-- Los default privileges del 0001 ya sacan EXECUTE a PUBLIC/anon; se repite explícito como
-- en mis_zonas(). authenticated necesita EXECUTE sobre el helper porque estado_cuenta()
-- corre con sus privilegios.
revoke all on function public.mis_campanias_vigentes(), public.estado_cuenta(),
  public.tg_usuario_suspension_servidor() from public, anon;
grant execute on function public.mis_campanias_vigentes(), public.estado_cuenta()
  to authenticated, service_role;
