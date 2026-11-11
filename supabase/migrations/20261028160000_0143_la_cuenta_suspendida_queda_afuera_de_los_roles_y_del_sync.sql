-- 0143 · La cuenta suspendida queda afuera de los roles y del sync (backend-supabase#203,
-- seguimiento de front-coordinadores-web#18 y #103; respuestas de Cristian del 27/10)
--
-- Caso: el administrador suspende a un coordinador por una licencia. Aunque tenga la sesión abierta
-- en el panel, la base ya no le devuelve datos. Y si suspende a un colportor, su teléfono deja de
-- hablar con el sync, avisa que la cuenta está suspendida y GUARDA todo lo que tenga sin subir
-- (nunca se descarta: las operaciones quedan pendientes, como con «Descartar op.») y lo sube cuando
-- la reactiven.
--
--   1. `tiene_rol()` descarta al usuario con `suspendido_en`. Es la puerta de casi todas las reglas
--      de acceso (156 usos en políticas y funciones): con ella, el ADMIN o el COORDINADOR suspendido
--      deja de tener rol para la base, aunque su sesión siga viva (revocarla pasa fuera de esta base
--      y puede llegar tarde, igual que con la baja administrativa, ADR-011). La fila propia de
--      `usuario` se sigue leyendo (política `usuario_select_propio_o_staff`, `id = auth.uid()`) y
--      `estado_cuenta()` sigue contestando SUSPENDIDA: es lo que el cliente necesita para mostrar el
--      aviso.
--   2. `public.sync_push()` y `public.sync_pull()` rechazan la llamada ENTERA de una cuenta suspendida
--      con el SQLSTATE `CS004` (la serie del contrato §6.1: CS001 a CS003). Corre antes que el sobre
--      y los topes: la cuenta suspendida no se discute con el formato del lote. El motor lo trata como
--      transitorio: los jobs quedan `PENDING` (no `INVALID`), igual que con `CS002`, y la app muestra
--      la cuenta suspendida. El código se suma a la tabla de rechazos del contrato en el mismo
--      cambio (docs-organizacion).
--
--   3. `mis_inscripciones_no_terminadas()` (de la que salen `mis_zonas()` y `mis_ciudades_de_trabajo()`),
--      `mis_campanias_vigentes()` y `mis_campanias_del_mapa()` (de la que salen `mis_campania_ciudades()`
--      y las políticas de `zona`, `campania_ciudad` y `precio_general`, también la rama del coordinador de
--      la campaña) no devuelven nada a la cuenta suspendida: lo compartido de su zona y
--      de su ciudad (casas, mapa) también se le cierra por la Data API directa (decisión del 28/10,
--      pendiente P2 de #203). Al reactivar vuelven solas.
--
-- Lo que NO cambia: las políticas de «lo propio» (`colportor_id = auth.uid()`: ventas, visitas, su
-- inscripción) siguen legibles para el colportor suspendido; no se esconde ni se pierde nada suyo.
-- Tampoco cambian `campanias_vigentes_de(usuario)` ni `inscripciones_no_terminadas_de(usuario)`: son
-- las que miran a OTRO usuario (por ejemplo, «ya está en otra campaña» al inscribir).
--
-- Forward-only: esta migración no se edita una vez aplicada.

-- ----------------------------------------------------------------------------
-- 1. tiene_rol(): la cuenta suspendida no tiene rol
-- ----------------------------------------------------------------------------

-- Igual que en 0001, más `u.suspendido_en is null`. Misma firma, así que conserva los privilegios.
create or replace function public.tiene_rol(p_codigo text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.usuario_rol ur
    join public.rol r on r.id = ur.rol_id
    join public.usuario u on u.id = ur.usuario_id
    where ur.usuario_id = auth.uid()
      and r.codigo = p_codigo
      and ur.deleted_at is null
      -- La baja administrativa (ADR-011) revoca las sesiones, pero eso pasa fuera de esta base.
      -- Si la revocación falla o llega tarde, el rol tiene que caerse igual acá.
      and u.deleted_at is null
      -- Lo mismo con la suspensión (HU-ADM-003, 0143): sin rol mientras dure; al reactivar, vuelve.
      and u.suspendido_en is null
      and r.deleted_at is null
      and (ur.valido_desde is null or ur.valido_desde <= now())
      and (ur.valido_hasta is null or ur.valido_hasta > now())
  );
$$;

comment on function public.tiene_rol(text) is
  '¿El usuario autenticado tiene el rol de negocio vigente? No lo tiene si su usuario está dado de '
  'baja (deleted_at) o suspendido (suspendido_en, 0143): la sesión puede seguir viva y la base igual '
  'no le devuelve datos.';

-- ----------------------------------------------------------------------------
-- 2. La puerta del sync rechaza a la cuenta suspendida
-- ----------------------------------------------------------------------------

-- INVOKER: lee la fila propia con la RLS de quien llama (usuario_select_propio_o_staff), como
-- estado_cuenta(). No recibe el usuario: sale de auth.uid().
create function sync.exigir_cuenta_no_suspendida()
returns void
language plpgsql
stable
security invoker
set search_path = ''
as $$
begin
  if exists (select 1 from public.usuario u
              where u.id = (select auth.uid()) and u.suspendido_en is not null) then
    raise exception 'La cuenta está suspendida. Lo que tengas sin subir queda guardado en el teléfono y se sube cuando un administrador la reactive.'
      using errcode = 'CS004',
            hint = 'no descartes nada: dejá los trabajos pendientes y reintentá cuando la cuenta vuelva a estar activa';
  end if;
end;
$$;

comment on function sync.exigir_cuenta_no_suspendida() is
  'Rechaza con CS004 la llamada de un usuario suspendido (usuario.suspendido_en no es null). La '
  'llaman public.sync_push() y public.sync_pull() antes de mirar el sobre (0143).';

revoke all on function sync.exigir_cuenta_no_suspendida() from public, anon;
grant execute on function sync.exigir_cuenta_no_suspendida() to authenticated, service_role;

-- Igual que en 0053, más la comprobación de la suspensión justo después de la de sesión.
create or replace function public.sync_push(p_body jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_device    uuid;
  v_jobs      jsonb;
  v_bytes     integer;
  v_respuesta jsonb;
begin
  -- Antes que el sobre: sin sesión no se le dice nada del pedido.
  if auth.uid() is null then
    raise exception 'sync_push requiere un usuario autenticado'
      using errcode = 'insufficient_privilege';
  end if;

  -- La cuenta suspendida no sube nada (CS004); el teléfono lo guarda y reintenta al reactivar.
  perform sync.exigir_cuenta_no_suspendida();

  v_device := sync.validar_sobre(p_body);

  v_jobs := p_body -> 'jobs';
  if jsonb_typeof(v_jobs) is distinct from 'array' then
    raise exception 'jobs tiene que ser un array de jobs'
      using errcode = 'invalid_parameter_value';
  end if;

  if jsonb_array_length(v_jobs) > 500 then
    raise exception 'lote de % jobs: el máximo es 500', jsonb_array_length(v_jobs)
      using errcode = 'CS003',
            hint = 'partí el lote y reintentá cada parte';
  end if;

  v_bytes := octet_length(v_jobs::text);
  if v_bytes > 1024 * 1024 then
    raise exception 'lote de % bytes: el máximo es 1 MB', v_bytes
      using errcode = 'CS003',
            hint = 'partí el lote y reintentá cada parte';
  end if;

  v_respuesta := sync.push(v_jobs, v_device);

  -- El servidor recibió datos de este teléfono (HU-CAM-008, S61).
  perform sync.registrar_push_recibido();

  return v_respuesta;
end;
$$;

comment on function public.sync_push(jsonb) is
  'Entrada del push del motor (POST /rest/v1/rpc/sync_push, ADR-013): rechaza con CS004 a la cuenta '
  'suspendida (0143), valida el sobre y los topes del lote (500 jobs, 1 MB; CS003), delega en '
  'sync.push() como quien llama (0042) y deja en usuario.ultimo_push_at el momento en que lo recibió '
  '(0053).';

-- Igual que en 0042, más la comprobación de la suspensión justo después de la de sesión.
create or replace function public.sync_pull(p_body jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_device    uuid;
  v_entidades text[];
  v_marca     jsonb;
  v_limite    integer;
  v_delta     jsonb;
begin
  if auth.uid() is null then
    raise exception 'sync_pull requiere un usuario autenticado'
      using errcode = 'insufficient_privilege';
  end if;

  -- La cuenta suspendida no baja nada (CS004).
  perform sync.exigir_cuenta_no_suspendida();

  v_device := sync.validar_sobre(p_body);

  if jsonb_typeof(p_body -> 'entities') is distinct from 'array'
     or exists (select 1 from jsonb_array_elements(p_body -> 'entities') e
                 where jsonb_typeof(e) <> 'string') then
    raise exception 'entities tiene que ser un array de nombres de entidad'
      using errcode = 'invalid_parameter_value';
  end if;
  v_entidades := array(select jsonb_array_elements_text(p_body -> 'entities'));

  -- Ausente o null: réplica desde cero. Si no, el string que devolvió el pull anterior.
  case coalesce(jsonb_typeof(p_body -> 'watermark'), 'null')
    when 'null' then
      v_marca := '{}'::jsonb;
    when 'string' then
      begin
        v_marca := (p_body ->> 'watermark')::jsonb;
      exception when invalid_text_representation then
        v_marca := null;
      end;
      if jsonb_typeof(v_marca) is distinct from 'object' then
        raise exception 'watermark no es uno que haya devuelto el pull'
          using errcode = 'invalid_parameter_value';
      end if;
    else
      raise exception 'watermark tiene que ser el string que devolvió el pull'
        using errcode = 'invalid_parameter_value';
  end case;

  -- Fuera de rango lo acota sync.pull() (0002); acá solo se pide que sea un entero.
  case coalesce(jsonb_typeof(p_body -> 'limit'), 'null')
    when 'null' then
      v_limite := null;
    when 'number' then
      begin
        v_limite := (p_body ->> 'limit')::integer;
      exception when invalid_text_representation or numeric_value_out_of_range then
        v_limite := null;
      end;
      if v_limite is null or v_limite::numeric <> (p_body ->> 'limit')::numeric then
        raise exception 'limit tiene que ser un entero'
          using errcode = 'invalid_parameter_value';
      end if;
    else
      raise exception 'limit tiene que ser un entero'
        using errcode = 'invalid_parameter_value';
  end case;

  -- Siempre 'ciudad': el colportor no elige el alcance (contrato 0.9.8, sección 4 del header).
  v_delta := sync.pull(v_entidades, v_marca, v_limite, v_device, 'ciudad');

  return jsonb_set(v_delta, '{watermark}', to_jsonb((v_delta -> 'watermark')::text));
end;
$$;

comment on function public.sync_pull(jsonb) is
  'Entrada del pull del motor (POST /rest/v1/rpc/sync_pull, ADR-013): rechaza con CS004 a la cuenta '
  'suspendida (0143), valida el sobre y delega en sync.pull() con alcance ciudad (contrato 0.9.8) '
  'como quien llama. El watermark viaja como string opaco (0042).';

-- ----------------------------------------------------------------------------
-- 3. Lo compartido de su zona y de su ciudad se le cierra a la cuenta suspendida
-- ----------------------------------------------------------------------------

-- Igual que en 0024, más `u.suspendido_en is null`. Alimenta a mis_zonas() y a mis_ciudades_de_trabajo()
-- (0013), que deciden qué casas y qué mapa ve un colportor (RLS de lectura y alcance «ciudad» del pull).
create or replace function public.mis_inscripciones_no_terminadas()
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
     and u.suspendido_en is null
     and c.deleted_at is null
     and (c.fecha_fin is null or c.fecha_fin >= public.hoy_montevideo());
$$;

comment on function public.mis_inscripciones_no_terminadas() is
  'Inscripciones vivas del usuario autenticado en campañas que no terminaron (en curso o por '
  'empezar), con su zona; ninguna si la cuenta está suspendida (0143). El día se cuenta en '
  'America/Montevideo (0024). Decide el mapa y las casas que ve y baja (0013; decisiones del 30/09 '
  'y del 02/10). Interna.';

-- Igual que en 0005 (delega en campanias_vigentes_de()), salvo que la cuenta suspendida no tiene
-- ninguna. campanias_vigentes_de(usuario) no cambia: mira a otro usuario.
create or replace function public.mis_campanias_vigentes()
returns table (campania_id uuid, zona_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select v.campania_id, v.zona_id
    from public.campanias_vigentes_de(auth.uid()) v
   where not exists (select 1 from public.usuario u
                      where u.id = auth.uid() and u.suspendido_en is not null);
$$;

-- Igual que en 0013, más `u.suspendido_en is null` en la rama del coordinador (la del colportor sale de
-- mis_inscripciones_no_terminadas(), arriba). De acá salen mis_campania_ciudades() y las políticas de
-- zona, campania_ciudad y precio_general: el coordinador suspendido ya no lee el mapa de su campaña.
create or replace function public.mis_campanias_del_mapa()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select c.id
    from public.campania c
    join public.usuario u on u.id = c.coordinador_id
   where c.coordinador_id = auth.uid() and u.deleted_at is null and u.suspendido_en is null
  union
  select i.campania_id from public.mis_inscripciones_no_terminadas() i;
$$;

comment on function public.mis_campanias_del_mapa() is
  'Campañas cuyo mapa ve el usuario autenticado: las que coordina y las que no terminaron (en '
  'curso o por empezar) en las que está inscripto (S56, 0013; decisión del 30/09); ninguna si la '
  'cuenta está suspendida (0143). La usan mis_campania_ciudades() y la huella del mapa en el pull.';
