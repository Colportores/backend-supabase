-- ============================================================================
-- 0116 · Quién cargó el acompañamiento: acompaniamiento_cargado_por (backend-supabase#173,
--        seguimiento de front-coordinadores-web#96, HU-JOR-004, vista 33 «Equipo»)
-- ============================================================================
-- Caso: Mariela abre en el panel el historial de acompañamientos de Emiliano. El canvas 33 dice «cargado por
-- vos» o «por X», pero la 0100 guarda solo el origen (COLPORTOR o COORDINADOR), no quién lo cargó.
--
-- Decisión del agente de decisiones del 26/10 (regla R1 del mapa: columna opcional que solo suma, sin texto
-- libre ni datos de clientes, y que el canvas ya promete): `pendientes/front-coordinadores-web-96-impl-261026-1100.md`,
-- P1. El panel muestra después «cargado por vos» o «por <nombre>» (front-coordinadores-web#98).
--
-- ## Qué cambia
--
--   1. `jornada.acompaniamiento_cargado_por uuid` (opcional, FK a `usuario` con ON DELETE SET NULL, como
--      `acompaniante_id`). Lo pone el servidor en `agregar_acompaniamiento()` con `auth.uid()` (el
--      coordinador de la campaña o el ADMIN que llama). Un cliente nunca lo manda: está entre las columnas
--      del servidor de `jornada` (el push la descarta) y el trigger de la 0100 la deja en null si el teléfono
--      marca o cambia al acompañante, o la conserva si no lo toca. Sin acompañante no hay quien cargó, y
--      un CHECK exige origen COORDINADOR: lo que marcó el colportor en el celular queda en null (el origen
--      ya dice que fue él).
--   2. `historial_de_acompaniamientos()` y `jornadas_cerradas_de_colportor()` devuelven tres columnas más
--      al final: `acompaniamiento_cargado_por` (uuid), `acompaniamiento_cargado_por_nombre` y
--      `acompaniamiento_cargado_por_apellido`, para que el panel muestre el nombre sin otra consulta (y
--      compare el uuid con el del usuario para decir «vos»). Cambian las columnas de salida, así que se
--      hace `drop function` y `create` (con `create or replace` quedaría una sobrecarga y PostgREST no
--      sabría a cuál llamar), y se vuelven a dar los privilegios.
--   3. `agregar_acompaniamiento()`: misma firma y mismas columnas de salida (`create or replace` conserva
--      los privilegios); suma la escritura de la columna. El reintento idempotente (ya figura esa misma
--      persona) no toca la fila, así que quien lo cargó primero sigue siendo quien lo cargó.
--
-- ## Qué no cambia
--
--   · Las filas anteriores quedan con la columna en null (los datos son simulados hasta diciembre): el
--     panel muestra solo «cargado desde el panel» sin nombre. No se inventa el dato.
--   · Sin tabla nueva, sin entidad nueva en `sync.entidad`: no hay que tocar los conteos de 0003/0037/0044.
--   · La auditoría ya tiene al actor (quien cargó) en `audit_log.actor_user_id`: no cambia el evento.
--   · `acompaniamientos_por_colportor()` no devuelve estos datos.
--
-- Forward-only: no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. La columna
-- ----------------------------------------------------------------------------

alter table public.jornada
  add column acompaniamiento_cargado_por uuid references public.usuario(id) on delete set null;

alter table public.jornada
  add constraint jornada_acompaniamiento_cargado_por_con_origen
    check (acompaniamiento_cargado_por is null or acompaniamiento_origen = 'COORDINADOR');

comment on column public.jornada.acompaniamiento_cargado_por is
  'Quién cargó el acompañamiento en el panel (0116, #173): el coordinador de la campaña o el ADMIN que '
  'llamó a agregar_acompaniamiento(). null = lo marcó el colportor en el celular (origen COLPORTOR), no hay '
  'acompañante o es anterior a la 0116 (no se sabe). Lo pone el servidor; el push la descarta.';

-- El push no la escribe (contrato §5.4): se descarta en silencio.
update sync.entidad
   set columnas_servidor = columnas_servidor || array['acompaniamiento_cargado_por']
 where nombre = 'jornada';

-- ----------------------------------------------------------------------------
-- 2. El trigger de la 0100: el cliente tampoco elige quién cargó
-- ----------------------------------------------------------------------------

create or replace function public.tg_jornada_acompaniamiento_servidor()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user in ('authenticated', 'anon') then
    if tg_op = 'INSERT' or new.acompaniante_id is distinct from old.acompaniante_id then
      new.acompaniamiento_origen := case when new.acompaniante_id is not null then 'COLPORTOR' end;
      new.acompaniamiento_nota := null;
      new.acompaniamiento_cargado_por := null;
    else
      new.acompaniamiento_origen := old.acompaniamiento_origen;
      new.acompaniamiento_nota := old.acompaniamiento_nota;
      new.acompaniamiento_cargado_por := old.acompaniamiento_cargado_por;
    end if;
  elsif new.acompaniante_id is null then
    -- También el servidor: sin acompañante no hay origen, nota ni quien lo cargó (el ON DELETE SET NULL de
    -- la FK pasa por acá).
    new.acompaniamiento_origen := null;
    new.acompaniamiento_nota := null;
    new.acompaniamiento_cargado_por := null;
  end if;
  return new;
end;
$$;

comment on function public.tg_jornada_acompaniamiento_servidor() is
  'BEFORE INSERT/UPDATE de jornada (0100, #140; 0116, #173): el origen, la nota y quien cargó el '
  'acompañamiento son del servidor. Un cliente que marca o cambia al acompañante deja origen COLPORTOR, '
  'sin nota y sin quien cargó; si no lo toca, se conserva lo que había. Sin acompañante no hay ninguno de '
  'los tres.';

-- ----------------------------------------------------------------------------
-- 3. Las lecturas del panel, con quién lo cargó
-- ----------------------------------------------------------------------------

drop function public.historial_de_acompaniamientos(uuid, uuid);
drop function public.jornadas_cerradas_de_colportor(uuid, uuid);

create function public.historial_de_acompaniamientos(p_campania_id uuid,
                                                     p_colportor_id uuid default null)
returns table (jornada_id uuid, colportor_id uuid, nombre text, apellido text, dia date,
               horas numeric, en_curso boolean, acompaniante_id uuid,
               acompaniante_nombre text, acompaniante_apellido text,
               acompaniamiento_origen text, acompaniamiento_nota text,
               acompaniamiento_cargado_por uuid, acompaniamiento_cargado_por_nombre text,
               acompaniamiento_cargado_por_apellido text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_motivo text;
begin
  v_motivo := public.motivo_mapa_de_campania(p_campania_id);
  if v_motivo = 'SIN_PERMISO' then
    raise exception 'Solo el coordinador de la campaña o un administrador puede ver sus acompañamientos. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_motivo is distinct from 'CAMPANIA_TERMINADA' then
    perform public.lanzar_motivo_mapa(v_motivo);
  end if;

  return query
    select h.jornada_id,
           h.colportor_id,
           usr.nombre,
           usr.apellido,
           h.dia,
           h.horas,
           h.en_curso,
           h.acompaniante_id,
           aco.nombre,
           aco.apellido,
           h.acompaniamiento_origen,
           h.acompaniamiento_nota,
           jor.acompaniamiento_cargado_por,
           car.nombre,
           car.apellido
      from public.jornadas_acompaniadas_de_campania(p_campania_id) h
      join public.jornada jor on jor.id = h.jornada_id
      join public.usuario usr on usr.id = h.colportor_id
      join public.usuario aco on aco.id = h.acompaniante_id
      left join public.usuario car on car.id = jor.acompaniamiento_cargado_por
     where p_colportor_id is null or h.colportor_id = p_colportor_id
     order by h.dia desc, h.jornada_id desc;
end;
$$;

comment on function public.historial_de_acompaniamientos(uuid, uuid) is
  'Vista 33, HU-JOR-004 (0043, backend-supabase#97; 0100, #140; 0116, #173): las jornadas acompañadas de la '
  'campaña (de p_colportor_id, o de todos si es null), la más nueva primero: día de Montevideo, horas de la '
  'jornada (null si sigue abierta), quién acompañó, de dónde salió el dato (acompaniamiento_origen: '
  'COLPORTOR | COORDINADOR | null si es anterior a la 0100), la nota y quién la cargó en el panel '
  '(acompaniamiento_cargado_por y su nombre y apellido: null si la marcó el colportor en el celular o es '
  'anterior a la 0116). Una campaña terminada se lee. Un colportor que no es de la campaña da la lista '
  'vacía. Errores: 42501 sin permiso; CZ001 campaña inexistente.';

revoke all on function public.historial_de_acompaniamientos(uuid, uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.historial_de_acompaniamientos(uuid, uuid) to authenticated;

create function public.jornadas_cerradas_de_colportor(p_campania_id uuid, p_colportor_id uuid)
returns table (jornada_id uuid, dia date, horas numeric, acompaniante_id uuid,
               acompaniante_nombre text, acompaniante_apellido text,
               acompaniamiento_origen text, acompaniamiento_nota text,
               acompaniamiento_cargado_por uuid, acompaniamiento_cargado_por_nombre text,
               acompaniamiento_cargado_por_apellido text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_motivo   text;
  v_campania public.campania;
begin
  v_motivo := public.motivo_mapa_de_campania(p_campania_id);
  if v_motivo = 'SIN_PERMISO' then
    raise exception 'Solo el coordinador de la campaña o un administrador puede ver sus jornadas. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_motivo is distinct from 'CAMPANIA_TERMINADA' then
    perform public.lanzar_motivo_mapa(v_motivo);
  end if;

  select * into v_campania from public.campania c where c.id = p_campania_id;

  -- Las mismas jornadas que cuentan para la campaña (fechas, baja y huecos de la inscripción, día de
  -- Montevideo), pero solo las cerradas, con o sin acompañante. Un colportor que no es de la campaña
  -- (o null) da la lista vacía.
  return query
    select j.id,
           public.hoy_montevideo(j.inicio),
           round(extract(epoch from (j.fin - j.inicio))::numeric / 3600, 2),
           j.acompaniante_id,
           aco.nombre,
           aco.apellido,
           j.acompaniamiento_origen,
           j.acompaniamiento_nota,
           j.acompaniamiento_cargado_por,
           car.nombre,
           car.apellido
      from public.campania_colportor i
      join public.jornada j on j.colportor_id = i.usuario_id
      left join public.usuario aco on aco.id = j.acompaniante_id
      left join public.usuario car on car.id = j.acompaniamiento_cargado_por
     where i.campania_id = p_campania_id
       and i.usuario_id = p_colportor_id
       and j.deleted_at is null
       and j.fin is not null
       and public.inscripcion_cubre_el_instante(i.created_at, i.deleted_at, i.tramos_afuera, j.inicio)
       and public.hoy_montevideo(j.inicio) >= v_campania.fecha_inicio
       and public.hoy_montevideo(j.inicio) <= coalesce(v_campania.fecha_fin, 'infinity'::date)
     order by public.hoy_montevideo(j.inicio) desc, j.inicio desc, j.id desc;
end;
$$;

comment on function public.jornadas_cerradas_de_colportor(uuid, uuid) is
  'Vista 33, HU-JOR-004 (0043, backend-supabase#97; 0100, #140; 0116, #173): las jornadas CERRADAS de '
  'p_colportor_id en la campaña (fechas de la campaña, desde el alta, antes de la baja y fuera de los '
  'huecos de la inscripción, día de Montevideo), la más nueva primero, con sus horas, quién la acompañó '
  '(null si nadie todavía), el origen, la nota y quién cargó el acompañamiento en el panel '
  '(acompaniamiento_cargado_por y su nombre y apellido; null si lo marcó el colportor o es anterior a la '
  '0116): de ahí elige el coordinador a cuál agregar su acompañamiento. Un colportor que no es de la '
  'campaña (o null) da la lista vacía. Una campaña terminada se lee. Errores: 42501 sin permiso; CZ001 '
  'campaña inexistente.';

revoke all on function public.jornadas_cerradas_de_colportor(uuid, uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.jornadas_cerradas_de_colportor(uuid, uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 4. Agregar un acompañamiento: ahora deja quién lo cargó
-- ----------------------------------------------------------------------------

create or replace function public.agregar_acompaniamiento(p_campania_id uuid, p_jornada_id uuid,
                                               p_acompaniante_id uuid default null,
                                               p_nota text default null)
returns table (jornada_id uuid, colportor_id uuid, dia date, acompaniante_id uuid,
               acompaniante_nombre text, acompaniante_apellido text, ya_estaba boolean,
               acompaniamiento_origen text, acompaniamiento_nota text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_motivo   text;
  v_campania public.campania;
  v_jornada  public.jornada;
  v_yo       uuid := auth.uid();
  v_acomp    uuid;
  v_nota     text;
  v_otro     text;
  v_origen   text;
begin
  -- El permiso, antes de mirar nada más.
  v_motivo := public.motivo_mapa_de_campania(p_campania_id);
  if v_motivo = 'SIN_PERMISO' then
    raise exception 'Solo el coordinador de la campaña o un administrador puede registrar acompañamientos. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;

  -- Una campaña terminada admite el registro hasta 15 días después de su fin: la misma regla de las
  -- ventas (escritura_dentro_de_plazo, 0020). Pasado el plazo, CZ011 como siempre.
  if v_motivo = 'CAMPANIA_TERMINADA' then
    select * into v_campania from public.campania c where c.id = p_campania_id;
    if not public.escritura_dentro_de_plazo(v_campania.fecha_fin) then
      raise exception 'La campaña terminó hace más de 15 días y sus acompañamientos quedan como están. Elegí una campaña en curso o que haya terminado hace 15 días o menos.'
        using errcode = 'CZ011';
    end if;
  else
    perform public.lanzar_motivo_mapa(v_motivo);
    select * into v_campania from public.campania c where c.id = p_campania_id;
  end if;

  if p_jornada_id is null then
    raise exception 'Elegí la jornada del colportor a la que querés agregar el acompañamiento.'
      using errcode = 'invalid_parameter_value';
  end if;

  -- La nota: sin espacios ni saltos de línea en los extremos; vacía es sin nota.
  v_nota := nullif(regexp_replace(coalesce(p_nota, ''), '^\s+|\s+$', '', 'g'), '');
  if char_length(v_nota) > 500 then
    raise exception 'La nota admite hasta 500 caracteres y esta tiene %. Acortala; no pongas datos de clientes.',
      char_length(v_nota)
      using errcode = 'invalid_parameter_value';
  end if;

  -- «Yo» (sin p_acompaniante_id, o el propio) u otro colportor.
  v_acomp := coalesce(p_acompaniante_id, v_yo);

  -- La jornada, solo si es de un colportor de esta campaña (inscripción vigente ese día y fuera de sus
  -- huecos, en las fechas de la campaña). Con candado: el doble toque y dos coordinadores se serializan acá.
  select j.* into v_jornada
    from public.jornada j
    join public.campania_colportor i
      on i.usuario_id = j.colportor_id and i.campania_id = p_campania_id
   where j.id = p_jornada_id
     and j.deleted_at is null
     and public.inscripcion_cubre_el_instante(i.created_at, i.deleted_at, i.tramos_afuera, j.inicio)
     and public.hoy_montevideo(j.inicio) >= v_campania.fecha_inicio
     and public.hoy_montevideo(j.inicio) <= coalesce(v_campania.fecha_fin, 'infinity'::date)
     for update of j;
  if not found then
    raise exception 'La jornada no existe o no es de un colportor de esta campaña. Recargá el historial del colportor y elegí otra.'
      using errcode = 'JO001';
  end if;

  if v_jornada.fin is null then
    raise exception 'La jornada todavía no terminó. Cuando el colportor la cierre vas a poder agregar el acompañamiento.'
      using errcode = 'JO002';
  end if;

  if v_jornada.colportor_id = v_acomp then
    raise exception '%',
      case when v_acomp = v_yo
           then 'No podés registrarte como acompañante de tu propia jornada. Elegí una jornada de otro colportor.'
           else 'Un colportor no puede figurar como acompañante de su propia jornada. Elegí a otra persona.' end
      using errcode = 'JO004';
  end if;

  -- Ya registrado por la misma persona: idempotente, no se toca la fila (ni se cambia la nota).
  -- Por otra: no se pisa (nunca se pierde un dato).
  if v_jornada.acompaniante_id is not null and v_jornada.acompaniante_id <> v_acomp then
    select trim(coalesce(u.nombre, '') || ' ' || coalesce(u.apellido, '')) into v_otro
      from public.usuario u where u.id = v_jornada.acompaniante_id;
    raise exception 'Esta jornada ya figura acompañada por %. El acompañamiento registrado no se cambia desde el panel.',
      coalesce(nullif(v_otro, ''), 'otra persona')
      using errcode = 'JO003';
  end if;

  if v_jornada.acompaniante_id is null then
    -- Otro colportor: tiene que estar inscripto (vivo) en la campaña de la jornada.
    if v_acomp <> v_yo and not exists (
         select 1 from public.campania_colportor ac
          where ac.campania_id = p_campania_id and ac.usuario_id = v_acomp and ac.deleted_at is null) then
      raise exception 'Ese colportor no está inscripto en esta campaña. Elegí a alguien de su equipo.'
        using errcode = 'JO005';
    end if;

    update public.jornada j
       set acompaniante_id = v_acomp,
           acompaniamiento_origen = 'COORDINADOR',
           acompaniamiento_nota = v_nota,
           acompaniamiento_cargado_por = v_yo
     where j.id = v_jornada.id;
    v_origen := 'COORDINADOR';

    -- Quién lo cargó (0116, #173): quien llama, que es el coordinador de la campaña o un ADMIN. Lo pone el
    -- servidor con auth.uid() y el cliente no lo elige. El reintento idempotente de abajo no lo toca.
    -- HU-JOR-004: «`audit_log` registra el cambio». Quién (actor) = quien lo cargó; sobre quién (target) = el
    -- colportor acompañado; el detalle, la campaña, el día, quién acompañó y si hubo nota: nunca nombres
    -- ni el texto de la nota.
    perform auditoria.registrar(
      'acompaniamiento_agregado', 'jornada', v_jornada.id, v_jornada.colportor_id,
      jsonb_build_object('campania_id', p_campania_id,
                         'dia', public.hoy_montevideo(v_jornada.inicio),
                         'acompaniante_id', v_acomp,
                         'con_nota', (v_nota is not null)));
  else
    v_nota := v_jornada.acompaniamiento_nota;
    v_origen := v_jornada.acompaniamiento_origen;
  end if;

  return query
    select v_jornada.id,
           v_jornada.colportor_id,
           public.hoy_montevideo(v_jornada.inicio),
           v_acomp,
           usr.nombre,
           usr.apellido,
           (v_jornada.acompaniante_id is not null),
           v_origen,
           v_nota
      from public.usuario usr
     where usr.id = v_acomp;
end;
$$;

comment on function public.agregar_acompaniamiento(uuid, uuid, uuid, text) is
  'Vista 33, HU-JOR-004 (0043, backend-supabase#97; 0073, #136; 0100 y 0103, #140; 0116, #173): el coordinador de la campaña '
  '(o un ADMIN) registra el acompañamiento de una jornada ya cerrada: el suyo («Yo», sin p_acompaniante_id) '
  'o el de otro colportor inscripto en la campaña, con una nota opcional (hasta 500 caracteres). Deja '
  'jornada.acompaniante_id, acompaniamiento_origen = COORDINADOR, la nota y, desde la 0116, '
  'acompaniamiento_cargado_por = quien llama, y el evento '
  'acompaniamiento_agregado en audit_log. Idempotente (ya_estaba, sin segundo registro ni cambio de nota) si '
  'ya figuraba esa misma persona; si la acompañó otra, JO003 y no se pisa. Una campaña terminada se acepta '
  'hasta 15 días después de su fin (0020). Errores: 42501 sin permiso; CZ001 campaña inexistente; CZ011 '
  'campaña terminada hace más de 15 días; 22023 sin jornada o nota de más de 500 caracteres; JO001 jornada '
  'que no es de un colportor de la campaña; JO002 jornada abierta; JO003 ya acompañada por otra persona; '
  'JO004 la jornada es de quien se quiere anotar como acompañante; JO005 el colportor elegido no está '
  'inscripto en la campaña.';

revoke all on function public.agregar_acompaniamiento(uuid, uuid, uuid, text)
  from public, anon, authenticated, service_role;
grant execute on function public.agregar_acompaniamiento(uuid, uuid, uuid, text) to authenticated;
