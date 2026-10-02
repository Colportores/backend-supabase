-- ============================================================================
-- 0021 · Corregir lo que se ve (el rechazo es visible, no un conflicto falso), el autor de una
--        casa escribe solo con campaña, y en los 15 días de gracia no se corrige lo ajeno
--        (backend-supabase#45, re-revisión del 02/10; #51, decisión del orquestador; #52 y #55,
--        decisiones de Cristian del 02/10)
--
-- ## 1. El UPDATE llega a lo que la lectura ya ve (hallazgo de la re-revisión de #45)
--
-- Re-revisión de #45 (comentario 5953241096): desde 0013 la lectura de ubicacion (y por ella la de
-- espacio y house_status) incluye las campañas que todavía no empezaron
-- (mis_ciudades_de_trabajo()), pero el USING de los UPDATE de 0011 y 0018 sigue pidiendo campaña
-- que ya empezó (mis_ciudades_de_campania(), puedo_escribir_en_ubicacion()). Antes del primer día,
-- el colportor ve una casa o un espacio ajeno, lo corrige, y el UPDATE no alcanza ninguna fila:
-- sync.aplicar_job_interno lo toma por «otro escritor ganó la carrera» y devuelve `conflict` con
-- server_row y la misma versión que mandó. El teléfono pisaba su corrección con la fila del
-- servidor, sin aviso (el mismo problema que 0018 arregló para el espacio propio).
--
-- Arreglo, como 0018: el USING suma lo que la lectura ve, y el WITH CHECK sigue pidiendo lo que
-- puede escribir. El UPDATE llega a la fila y el WITH CHECK la rechaza con 42501: el push lo
-- devuelve `invalid`, visible en la cola de error, sin reintento automático. Se redefinen las tres
-- políticas (la de espacio, tal como la dejó 0018):
--   · ubicacion_por_ciudad_update: USING suma `ciudad_id in mis_ciudades_de_trabajo()` (lo que
--     ve por ciudad).
--   · house_status_por_ubicacion_update y espacio_por_ubicacion_update: USING suma
--     `exists (select 1 from ubicacion u where u.id = ubicacion_id)` (lo que ve de la casa).
-- Lo que ya no ve sigue igual: FILA_INEXISTENTE (`invalid`).
--
-- ## 2. Mover algo que solo ve (hallazgo de la revisión de #55)
--
-- El WITH CHECK mira solo la fila nueva, y hasta 0020 el USING exigía poder escribir también en la
-- fila de antes. Con el USING ampliado, un UPDATE que cambia `ubicacion.ciudad_id`,
-- `espacio.ubicacion_id` o `house_status.ubicacion_id` desde algo que solo ve (una casa de una
-- campaña por empezar) hacia algo donde escribe pasaba las dos políticas: la casa ajena se iba a
-- otra ciudad, el depto ajeno (con su persona, su visita y su venta) se mudaba a otra casa. El
-- control de la fila de antes pasa a un trigger BEFORE UPDATE (tg_control_de_correccion): si el
-- cambio mueve la fila y la de antes no se podía escribir, 42501.
--
-- ## 3. El autor de una casa escribe solo con campaña, y las altas no miran la campaña
--
-- Decisión del orquestador (#51, comentario 5953264962; coherencia con la de Cristian del 02/10,
-- comentario 5951900059, «solo con campaña vigente»): la rama «la registró él» de
-- puedo_escribir_en_ubicacion() dejaba al autor seguir corrigiendo los espacios y estados de su
-- casa para siempre. Pasa a exigir alguna campaña en la que se puede escribir
-- (mis_campanias_para_escribir(), 0020: ya empezó, y no terminó o terminó hace 15 días o menos).
-- Decisión de Cristian del 02/10 (#55, comentario 5954250933): alcanza con ALGUNA campaña vigente
-- o dentro de la gracia, aunque sea en otra ciudad.
--   · Vale también para la casa misma (revisión de #55): pasados la campaña y los 15 días, el
--     autor no corrige, no muda ni da de baja su ubicación (WITH CHECK de ubicacion, 42501).
--   · Las ALTAS no miran la campaña, como antes de esta migración: cargar el espacio y el estado
--     en una casa nueva propia, antes del primer día, entra (las casas también se cargan antes de
--     que empiece la campaña, igual que el mapa). Las políticas de INSERT de espacio y
--     house_status usan puedo_cargar_en_ubicacion(): la registró él o es de una ciudad de sus
--     campañas en las que puede escribir. En una casa ajena, el alta sigue pidiendo campaña.
--   · No cambia lo que ve: la lectura del autor (created_by) sigue.
--
-- ## 4. En los 15 días de gracia no se corrige lo ajeno (decisión de Cristian del 02/10, #52)
--
-- Decisión de Cristian (#52, comentario 5954249444): en los 15 días de gracia entran solo las
-- ventas y las altas, y las correcciones de filas propias. Las correcciones de filas ajenas
-- (ubicacion, espacio o house_status que cargó otro) que suben después del fin de la campaña se
-- rechazan con un código propio, CG001, que el teléfono distingue del 42501 y traduce a un aviso.
--   · Se rechaza si la fila la cargó otro (created_by distinto) y el colportor escribe en ella
--     solo por la gracia: ninguna campaña en curso (sin terminar) lo habilita
--     (ubicacion_solo_en_gracia()). Con otra campaña en curso que cubre la ciudad, entra.
--   · El push lo devuelve `invalid` con code `CG001`, sin tumbar el lote. Como la lectura no tiene
--     gracia (la fila ajena ya no se ve), el push la rechaza ANTES de leerla
--     (sync.aplicar_job_interno llama a correccion_ajena_en_gracia()): sin eso volvía
--     FILA_INEXISTENTE. Un UPDATE directo sobre algo que ya no ve sigue sin tocar nada (RLS de
--     lectura); sobre algo que ve, lo rechaza el trigger con CG001.
--   · «En curso» se cuenta en la hora de America/Montevideo, como la gracia (0020).
--   · Lo que entra en la gracia: ventas, visitas, personas, altas de ubicación, espacio y estado
--     (propios o en casa ajena), y la corrección de lo que cargó el propio colportor.
--
-- ## Para otros repos
--
--   · front-colportores-mobile y motor (#178), códigos de `invalid` del push:
--       - `CG001`: corrección de una casa, un espacio o un estado ajeno después del fin de la
--         campaña (dentro de los 15 días). La fila queda como estaba. Avisar: «La campaña ya
--         terminó: solo se guardan tus ventas y lo que cargaste vos. Descartá este cambio.»
--       - `42501`: corregir una casa, un espacio o un estado ajeno antes del primer día de la
--         campaña (antes `conflict` con server_row); corregir lo propio (la casa, su espacio o su
--         estado) con la campaña terminada hace más de 15 días y sin otra campaña; mover una fila
--         desde algo en lo que no escribe; y el ALTA de un espacio o un estado en una casa AJENA
--         sin campaña en la que escribir. El alta en una casa PROPIA no mira la campaña: entra
--         (también la venta que cuelga de ella).
--   · Las correcciones de lo propio entran en la gracia (día 15 incluido).
--
-- Datos: ninguno cambia; se reemplazan políticas y funciones y se suman triggers.
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Funciones de la regla (internas)
-- ----------------------------------------------------------------------------

-- Si una campaña que termina en p_fecha_fin está en curso en p_ahora (no terminó), contado en la
-- hora de America/Montevideo, como la gracia (0020). Pura.
create function public.escritura_en_curso(p_fecha_fin date, p_ahora timestamptz default now())
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_fecha_fin is null
      or p_fecha_fin >= (p_ahora at time zone 'America/Montevideo')::date;
$$;

comment on function public.escritura_en_curso(date, timestamptz) is
  'Si una campaña que termina en p_fecha_fin todavía no terminó en p_ahora, en la hora de '
  'America/Montevideo (0021). La gracia de 0020 es lo que viene después, hasta 15 días.';

-- Como mis_campanias_para_escribir() (0020), pero sin la gracia: solo las que no terminaron.
create function public.mis_campanias_en_curso_para_escribir()
returns table (campania_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select m.campania_id
    from public.mis_campanias_para_escribir() m
    join public.campania c on c.id = m.campania_id
   where public.escritura_en_curso(c.fecha_fin);
$$;

comment on function public.mis_campanias_en_curso_para_escribir() is
  'Campañas del usuario autenticado en las que puede escribir sin la gracia: ya empezadas y sin '
  'terminar (0021). Interna.';

create function public.mis_ciudades_de_campania_en_curso()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select distinct cc.ciudad_id
    from public.mis_campanias_en_curso_para_escribir() v
    join public.campania_ciudad cc on cc.campania_id = v.campania_id
   where cc.deleted_at is null;
$$;

comment on function public.mis_ciudades_de_campania_en_curso() is
  'Ciudades vivas de las campañas en curso del usuario autenticado (sin la gracia de 0020). '
  'Interna (0021).';

-- Si el usuario autenticado tiene alguna campaña en la que escribir (en curso o dentro de la
-- gracia). La usa el WITH CHECK de ubicacion: SECURITY DEFINER para que authenticated no necesite
-- el EXECUTE de mis_campanias_para_escribir().
create function public.tengo_campania_para_escribir()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.mis_campanias_para_escribir());
$$;

comment on function public.tengo_campania_para_escribir() is
  'Si el usuario autenticado tiene alguna campaña en la que puede escribir: ya empezada y sin '
  'terminar o terminada hace 15 días o menos (0020, 0021). La usa la política de ubicacion.';

-- Si el usuario autenticado puede CORREGIR lo ajeno en la ubicación sin la gracia: es de una
-- ciudad de una campaña en curso, o la registró él y tiene una campaña en curso.
create function public.puedo_corregir_ajeno_en_ubicacion(p_ubicacion_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.ubicacion u
                  where u.id = p_ubicacion_id
                    and ((u.created_by = auth.uid()
                          and exists (select 1 from public.mis_campanias_en_curso_para_escribir()))
                         or u.ciudad_id in (select public.mis_ciudades_de_campania_en_curso())));
$$;

comment on function public.puedo_corregir_ajeno_en_ubicacion(uuid) is
  'Si el usuario autenticado corrige lo que cargó otro en la ubicación: campaña en curso (sin la '
  'gracia de 0020) en su ciudad, o la registró él y tiene una campaña en curso (0021). Interna.';

-- La regla de la gracia: escribe en la ubicación (puedo_escribir_en_ubicacion()), pero solo
-- porque la campaña terminó hace 15 días o menos.
create function public.ubicacion_solo_en_gracia(p_ubicacion_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.puedo_escribir_en_ubicacion(p_ubicacion_id)
     and not public.puedo_corregir_ajeno_en_ubicacion(p_ubicacion_id);
$$;

comment on function public.ubicacion_solo_en_gracia(uuid) is
  'Si el usuario autenticado escribe en la ubicación solo por los 15 días de gracia de 0020, sin '
  'ninguna campaña en curso que lo habilite (0021). Interna.';

-- Si corregir (o dar de baja) esa fila sería una corrección ajena en la gracia: la cargó otro y
-- el colportor escribe en su casa solo por la gracia. p_entidad es la de sync (ubicacion,
-- espacio, house_status) y p_pk su clave (en house_status, la ubicación). Sin pasar por la RLS de
-- lectura: la gracia no tiene lectura, y justamente la fila ajena ya no se ve. Cualquier otra
-- entidad, o una fila que no existe: false. La llama sync.aplicar_job_interno() (0021).
create function public.correccion_ajena_en_gracia(p_entidad text, p_pk uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select case p_entidad
      when 'ubicacion' then
        (select u.created_by is distinct from auth.uid()
                and public.ubicacion_solo_en_gracia(u.id)
           from public.ubicacion u where u.id = p_pk)
      when 'espacio' then
        (select e.created_by is distinct from auth.uid()
                and public.ubicacion_solo_en_gracia(e.ubicacion_id)
           from public.espacio e where e.id = p_pk)
      when 'house_status' then
        (select h.created_by is distinct from auth.uid()
                and public.ubicacion_solo_en_gracia(h.ubicacion_id)
           from public.house_status h where h.ubicacion_id = p_pk)
    end), false);
$$;

comment on function public.correccion_ajena_en_gracia(text, uuid) is
  'Si corregir esa fila (ubicacion, espacio o house_status) es corregir lo que cargó otro con la '
  'campaña terminada hace 15 días o menos y ninguna en curso: el push la rechaza con CG001 '
  '(0021, decisión de Cristian del 02/10 en #52).';

-- El alta no mira la campaña en la casa propia: la registró él o es de una ciudad de sus
-- campañas en las que puede escribir. SECURITY DEFINER como puedo_escribir_en_ubicacion().
create function public.puedo_cargar_en_ubicacion(p_ubicacion_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.ubicacion u
                  where u.id = p_ubicacion_id
                    and (u.created_by = auth.uid()
                         or u.ciudad_id in (select public.mis_ciudades_de_campania())));
$$;

comment on function public.puedo_cargar_en_ubicacion(uuid) is
  'Si el usuario autenticado puede dar de alta un espacio o un estado en la ubicación: la registró '
  'él (sin mirar la campaña: las casas también se cargan antes de que empiece), o es de una ciudad '
  'de sus campañas en las que puede escribir (mis_ciudades_de_campania()). Las políticas de INSERT '
  'de espacio y house_status (0021).';

-- Misma firma que en 0011; cambia la rama del autor: exige alguna campaña en la que escribir.
create or replace function public.puedo_escribir_en_ubicacion(p_ubicacion_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.ubicacion u
                  where u.id = p_ubicacion_id
                    and ((u.created_by = auth.uid()
                          and exists (select 1 from public.mis_campanias_para_escribir()))
                         or u.ciudad_id in (select public.mis_ciudades_de_campania())));
$$;

comment on function public.puedo_escribir_en_ubicacion(uuid) is
  'Si el usuario autenticado corrige la ubicación o le corrige espacios y estados: estando '
  'inscripto en una campaña en la que puede escribir (ya empezada, y sin terminar o terminada hace '
  '15 días o menos: mis_campanias_para_escribir(), 0020), y la registró él (con cualquiera de '
  'ellas) o es de una ciudad de esas campañas (mis_ciudades_de_campania()). Las altas usan '
  'puedo_cargar_en_ubicacion(). Sin pasar por la RLS de lectura (0021).';

-- ----------------------------------------------------------------------------
-- 2. Las políticas de UPDATE llegan a lo que la lectura ve; el autor, con campaña
-- ----------------------------------------------------------------------------

drop policy ubicacion_por_ciudad_update on public.ubicacion;
create policy ubicacion_por_ciudad_update on public.ubicacion
  for update to authenticated
  using (created_by = (select auth.uid())
         or ciudad_id in (select public.mis_ciudades_de_campania())
         or ciudad_id in (select public.mis_ciudades_de_trabajo()))
  with check ((created_by = (select auth.uid()) and (select public.tengo_campania_para_escribir()))
              or ciudad_id in (select public.mis_ciudades_de_campania()));

drop policy house_status_por_ubicacion_update on public.house_status;
create policy house_status_por_ubicacion_update on public.house_status
  for update to authenticated
  using (created_by = (select auth.uid())
         or public.puedo_escribir_en_ubicacion(ubicacion_id)
         or exists (select 1 from public.ubicacion u where u.id = ubicacion_id))
  with check (public.puedo_escribir_en_ubicacion(ubicacion_id));

drop policy espacio_por_ubicacion_update on public.espacio;
create policy espacio_por_ubicacion_update on public.espacio
  for update to authenticated
  using (created_by = (select auth.uid())
         or public.puedo_escribir_en_ubicacion(ubicacion_id)
         or exists (select 1 from public.ubicacion u where u.id = ubicacion_id))
  with check (public.puedo_escribir_en_ubicacion(ubicacion_id));

-- Las altas: la casa propia no mira la campaña.
drop policy espacio_por_ubicacion_insert on public.espacio;
create policy espacio_por_ubicacion_insert on public.espacio
  for insert to authenticated
  with check (created_by = (select auth.uid())
              and public.puedo_cargar_en_ubicacion(ubicacion_id));

drop policy house_status_por_ubicacion_insert on public.house_status;
create policy house_status_por_ubicacion_insert on public.house_status
  for insert to authenticated
  with check (created_by = (select auth.uid())
              and public.puedo_cargar_en_ubicacion(ubicacion_id));

comment on policy ubicacion_por_ciudad_update on public.ubicacion is
  'Corrige quien la registró (con alguna campaña en la que escribir) o quien trabaja en la ciudad. '
  'USING: lo que ve (también las campañas por empezar), para que el rechazo llegue como 42501 '
  'visible y no como un conflicto falso. WITH CHECK: solo lo que puede escribir. Mover una fila '
  'desde algo en lo que no escribe lo corta tg_control_de_correccion (0021).';

-- ----------------------------------------------------------------------------
-- 3. Trigger: mover solo lo que se puede escribir, y no corregir lo ajeno en la gracia
-- ----------------------------------------------------------------------------

-- BEFORE UPDATE de ubicacion, espacio y house_status, de un usuario autenticado y de primer nivel
-- (los UPDATE que salen de otros triggers, como el republicado de 0011, no pasan por acá).
--   1. Si el UPDATE mueve la fila (ciudad_id en ubicacion; ubicacion_id en espacio y
--      house_status), la fila de antes tiene que ser escribible: la ubicación (o, en espacio y
--      house_status, ser suyo lo que cargó, como el USING). 42501.
--   2. Corregir lo que cargó otro en la gracia: CG001. El push lo rechaza antes
--      (correccion_ajena_en_gracia()); esto cubre el UPDATE directo sobre lo que ve.
create function public.tg_control_de_correccion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ubicacion uuid;
  v_mueve     boolean;
  v_propia    boolean;
begin
  if auth.uid() is null or pg_trigger_depth() > 1 then
    return new;
  end if;

  if tg_table_name = 'ubicacion' then
    v_ubicacion := old.id;
    v_mueve := old.ciudad_id is distinct from new.ciudad_id;
    v_propia := false;
  else
    v_ubicacion := old.ubicacion_id;
    v_mueve := old.ubicacion_id is distinct from new.ubicacion_id;
    v_propia := old.created_by = auth.uid();
  end if;

  if v_mueve and not (v_propia or public.puedo_escribir_en_ubicacion(v_ubicacion)) then
    raise exception using
      errcode = '42501',
      message = 'No se puede mover: no podés escribir donde está ahora. La fila queda como estaba.';
  end if;

  if old.created_by is distinct from auth.uid() and public.ubicacion_solo_en_gracia(v_ubicacion) then
    raise exception using
      errcode = 'CG001',
      message = 'La campaña ya terminó: solo se guardan tus ventas y lo que cargaste vos. Lo que '
                'cargó otra persona queda como estaba.',
      hint    = 'Descartá este cambio.';
  end if;

  return new;
end;
$$;

comment on function public.tg_control_de_correccion() is
  'BEFORE UPDATE de ubicacion, espacio y house_status: mover una fila (ciudad_id o ubicacion_id) '
  'exige poder escribir donde estaba (42501), y corregir lo que cargó otro con la campaña en la '
  'gracia de 0020 es CG001. Solo de primer nivel y con usuario autenticado (0021).';

create trigger ubicacion_control_de_correccion
  before update on public.ubicacion
  for each row execute function public.tg_control_de_correccion();
create trigger espacio_control_de_correccion
  before update on public.espacio
  for each row execute function public.tg_control_de_correccion();
create trigger house_status_control_de_correccion
  before update on public.house_status
  for each row execute function public.tg_control_de_correccion();

-- ----------------------------------------------------------------------------
-- 4. El push: CG001 antes de leer la fila, y vuelve invalid sin tumbar el lote
-- ----------------------------------------------------------------------------

-- Igual que en 0002, más el control de la gracia antes de leer la fila (la lectura no tiene
-- gracia: sin esto, la corrección ajena en la gracia volvía FILA_INEXISTENTE).
create or replace function sync.aplicar_job_interno(p_op_id uuid, p_job jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_entidad   text  := p_job ->> 'entity';
  v_op        text  := p_job ->> 'op';
  v_version   bigint;
  v_payload   jsonb := p_job -> 'payload';
  v_tabla     regclass;
  v_pk_col    text;
  v_push_ok   boolean;
  v_pk        uuid;
  v_usadas    text[];
  v_cache     sync.op_cache%rowtype;
  v_actual    jsonb;
  v_nueva     bigint;
  -- EXECUTE no toca FOUND en PL/pgSQL: hay que leer ROW_COUNT a mano. Con FOUND,
  -- un insert que chocó con una PK existente se reportaría `accepted` porque la
  -- variable venía en true de un SELECT anterior.
  v_filas     integer;
begin
  if p_op_id is null then
    return sync.rechazo(p_op_id, 'OP_ID_REQUERIDO', 'falta client_op_id o no es un uuid');
  end if;

  -- El cache gana sobre cualquier validación. Un op ya aplicado vuelve
  -- `duplicate` y no se re-valida: si no, un job aplicado cuya respuesta se
  -- perdió y que en el reintento cae en una validación quedaría INVALID con la
  -- fila ya escrita, y el colportor vería en la cola de error una venta que ya
  -- cobró. Como acá solo entra lo aplicado, un conflicto anterior no lo activa.
  select * into v_cache from sync.op_cache where client_op_id = p_op_id;
  if found then
    return jsonb_build_object('client_op_id', p_op_id, 'outcome', 'duplicate',
                              'sync_version', v_cache.sync_version);
  end if;

  select e.tabla, e.columna_pk, e.permite_push
    into v_tabla, v_pk_col, v_push_ok
    from sync.entidad e where e.nombre = v_entidad;
  if v_tabla is null then
    return sync.rechazo(p_op_id, 'ENTIDAD_DESCONOCIDA',
                        format('%L no está registrada para sync', v_entidad));
  end if;

  if not v_push_ok then
    return sync.rechazo(p_op_id, 'ENTIDAD_DE_SOLO_LECTURA',
                        format('%L es una réplica: la app no la escribe', v_entidad));
  end if;

  v_pk := (v_payload ->> v_pk_col)::uuid;
  if v_pk is null then
    return sync.rechazo(p_op_id, 'PK_FALTANTE',
                        format('el payload no trae %L', v_pk_col));
  end if;

  -- Solo las columnas que el cliente puede escribir (contrato §5.4). Las del
  -- servidor se descartan aunque vengan.
  select array_agg(k) into v_usadas
    from jsonb_object_keys(v_payload) k
   where k = any (sync.columnas_escribibles(v_entidad));

  if v_usadas is null then
    return sync.rechazo(p_op_id, 'PAYLOAD_VACIO',
                        'el payload no trae ninguna columna escribible');
  end if;

  -- ---- insert ----
  if v_op = 'insert' then
    execute format(
      'insert into %s (%s) select %s from jsonb_populate_record(null::%s, $1) x '
      'on conflict (%I) do nothing',
      v_tabla,
      (select string_agg(quote_ident(c), ', ' order by c) from unnest(v_usadas) c),
      (select string_agg('x.' || quote_ident(c), ', ' order by c) from unnest(v_usadas) c),
      v_tabla, v_pk_col
    ) using v_payload;
    get diagnostics v_filas = row_count;

    execute format('select t.sync_version from %s t where t.%I = $1', v_tabla, v_pk_col)
      into v_nueva using v_pk;

    -- La PK ya existía: el UUID v7 lo generó el dispositivo, así que es la misma
    -- fila y no otra. Éxito idempotente, no error (contrato §7, replay).
    return sync.registrar(p_op_id, v_entidad,
                          case when v_filas > 0 then 'accepted' else 'duplicate' end, v_nueva);
  end if;

  if v_op not in ('update', 'delete') then
    return sync.rechazo(p_op_id, 'OP_INVALIDA', format('op %L', v_op));
  end if;

  -- ---- update / delete ----
  begin
    v_version := (p_job ->> 'sync_version')::bigint;
  exception when data_exception then
    v_version := null;
  end;

  -- 0021: corregir lo que cargó otro con la campaña en la gracia de 0020 (decisión de Cristian
  -- del 02/10 en #52). Antes de leer la fila: la lectura no tiene gracia y no la vería.
  if public.correccion_ajena_en_gracia(v_entidad, v_pk) then
    return sync.rechazo(p_op_id, 'CG001',
                        'La campaña ya terminó: solo se guardan tus ventas y lo que cargaste vos. Lo '
                        'que cargó otra persona queda como estaba. Descartá este cambio.');
  end if;

  execute format('select %s from %s t where t.%I = $1',
                 sync.expresion_json(v_tabla), v_tabla, v_pk_col)
    into v_actual using v_pk;
  if v_actual is null then
    return sync.rechazo(p_op_id, 'FILA_INEXISTENTE',
                        format('%s no existe en %s', v_pk, v_entidad));
  end if;

  -- LWW por sync_version (contrato §5.4). Si el servidor tiene una más nueva,
  -- gana él y devuelve su fila: el cliente resuelve sin un pull extra.
  if v_version is null or (v_actual ->> 'sync_version')::bigint <> v_version then
    return jsonb_build_object(
      'client_op_id', p_op_id, 'outcome', 'conflict',
      'sync_version', (v_actual ->> 'sync_version')::bigint,
      'server_row', v_actual);
  end if;

  -- La versión va en el WHERE del propio UPDATE, no solo en el `if` de arriba.
  --
  -- Entre aquel SELECT y este UPDATE hay una ventana: en READ COMMITTED otra
  -- transacción puede bumpear la fila justo ahí. El UPDATE quedaría esperando el
  -- lock, y al soltarse re-leería la fila y escribiría igual, pisando el cambio
  -- ajeno y devolviendo `accepted` con una versión que el cliente creía vieja.
  -- Es la actualización perdida clásica, y acá significa que el estado de una
  -- ubicación que dos dispositivos tocaron a la vez queda en el que llegó
  -- primero, sin que nadie se entere.
  --
  -- Con la versión en el WHERE es un compare-and-swap: o aplica sobre la versión
  -- que el cliente esperaba, o no aplica y se reporta como conflicto.
  --
  -- sync_version, updated_at y xmin_w no se asignan acá: los pone el trigger de
  -- auditoría del 0001 (§8), que corre igual venga la escritura de donde venga.
  if v_op = 'delete' then
    execute format('update %s t set deleted_at = now() where t.%I = $1 and t.sync_version = $2',
                   v_tabla, v_pk_col) using v_pk, v_version;
  else
    execute format(
      'update %s t set %s from jsonb_populate_record(null::%s, $1) x '
      'where t.%I = $2 and t.sync_version = $3',
      v_tabla,
      (select string_agg(format('%I = x.%I', c, c), ', ' order by c) from unnest(v_usadas) c),
      v_tabla, v_pk_col
    ) using v_payload, v_pk, v_version;
  end if;
  get diagnostics v_filas = row_count;

  if v_filas = 0 then
    -- Otro escritor ganó la carrera entre el SELECT y el UPDATE.
    execute format('select %s from %s t where t.%I = $1',
                   sync.expresion_json(v_tabla), v_tabla, v_pk_col)
      into v_actual using v_pk;
    return jsonb_build_object(
      'client_op_id', p_op_id, 'outcome', 'conflict',
      'sync_version', (v_actual ->> 'sync_version')::bigint,
      'server_row', v_actual);
  end if;

  execute format('select t.sync_version from %s t where t.%I = $1', v_tabla, v_pk_col)
    into v_nueva using v_pk;
  return sync.registrar(p_op_id, v_entidad, 'accepted', v_nueva);
end;
$$;

-- Igual que en 0018, más CG001.
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
  -- La baja de una casa con ventas o con visitas de otro colportor (0018) y la corrección ajena en la
  -- gracia (CG001, 0021): códigos propios, que
  -- la app traduce a un aviso. INVALID como el resto, sin tumbar el lote.
  when sqlstate 'UB001' or sqlstate 'UB002' or sqlstate 'CG001' then
    return jsonb_build_object(
      'client_op_id', v_id,
      'outcome', 'invalid',
      'code', sqlstate,
      'message', sqlerrm
    );
end;
$$;

-- ----------------------------------------------------------------------------
-- 5. Comentarios que habían quedado viejos
-- ----------------------------------------------------------------------------

comment on function public.mis_ciudades_de_campania() is
  'Ciudades vivas de las campañas del usuario autenticado en las que puede escribir: ya empezadas '
  'y sin terminar o terminadas hace 15 días o menos (0020), tenga zona o no. Decide dónde carga '
  'espacios y estados y dónde corrige lo propio; corregir lo ajeno en la gracia lo rechaza '
  'CG001 (0021).';

-- ----------------------------------------------------------------------------
-- 6. Privilegios
-- ----------------------------------------------------------------------------

-- `authenticated` también en el revoke: los default privileges de la imagen le dan EXECUTE sobre
-- cada función nueva de public (ver 0008).
revoke all on function
  public.escritura_en_curso(date, timestamptz),
  public.mis_campanias_en_curso_para_escribir(),
  public.mis_ciudades_de_campania_en_curso(),
  public.tengo_campania_para_escribir(),
  public.puedo_corregir_ajeno_en_ubicacion(uuid),
  public.ubicacion_solo_en_gracia(uuid),
  public.correccion_ajena_en_gracia(text, uuid),
  public.puedo_cargar_en_ubicacion(uuid),
  public.tg_control_de_correccion()
  from public, anon, authenticated;

-- Las usan las políticas (puedo_cargar_en_ubicacion, tengo_campania_para_escribir) y el push
-- (correccion_ajena_en_gracia), que corren como quien llama. Solo miran al usuario autenticado.
grant execute on function
  public.puedo_cargar_en_ubicacion(uuid),
  public.tengo_campania_para_escribir(),
  public.correccion_ajena_en_gracia(text, uuid)
  to authenticated, service_role;
