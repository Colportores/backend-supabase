-- ============================================================================
-- 0133 · La nota del acompañamiento y su origen salen de `jornada` y los lee solo coordinación
--        (backend-supabase#204, seguimiento de #140 / PR 160, HU-JOR-004, vista 33 «Equipo»)
-- ============================================================================
-- Caso: Mariela, coordinadora, registra en el panel un acompañamiento de Emiliano y escribe «Le costó arrancar;
-- mejoró a la tarde». Emiliano nunca la ve: ni en la app, ni en el pull, ni en la fila que le devuelve el
-- servidor al subir un cambio viejo de esa jornada.
--
-- Decisión de Cristian del 27/10, «Nota visible» (PR 160, comentario 6441655799): la nota es interna, la leen
-- coordinadores y Administración. Hasta la 0132 la nota (y su origen) vivían en `jornada.acompaniamiento_nota` y
-- `jornada.acompaniamiento_origen`: el colportor las leía por la RLS de lectura del dueño y las recibía en el
-- `server_row` de un conflicto del push.
--
-- ## Qué cambia
--
--   1. Tabla nueva `jornada_acompaniamiento` (una fila por jornada con acompañante y origen conocido):
--      `jornada_id`, `origen` (COLPORTOR | COORDINADOR) y `nota` (opcional, hasta 500 caracteres visibles, sin
--      espacios en los extremos, solo con origen COORDINADOR: las mismas reglas de la 0100 y la 0103). La
--      escribe SOLO el servidor; la lee, por RLS, el ADMIN y el coordinador de la campaña de la jornada
--      (`puede_leer_el_acompaniamiento()`). Ni anon ni el colportor (tampoco el de la jornada) la ven. No está
--      en `sync.entidad`: no viaja por el sync.
--   2. Se mueve lo que había (nada se pierde): cada jornada con acompañante y origen pasa a la tabla nueva con
--      su origen y su nota; las de origen `null` (anteriores a la 0100: no se sabe) siguen sin fila. Una
--      verificación dentro de la migración aborta si no coincide la cuenta o alguna nota.
--   3. `jornada` pierde `acompaniamiento_origen` y `acompaniamiento_nota` (con sus CHECK) y las saca de
--      `sync.entidad.columnas_servidor`: el pull, el `server_row` del conflicto y el SELECT del dueño ya no las
--      tienen. El CHECK que ataba `acompaniamiento_cargado_por` al origen COORDINADOR pasa a exigir solo que
--      haya acompañante (el trigger de la 0116 ya lo vaciaba sin acompañante).
--   4. Quién las mantiene:
--        · el teléfono marca o cambia al acompañante (push o INSERT/UPDATE con JWT de cliente) → un trigger
--          AFTER (SECURITY DEFINER) deja la fila con origen COLPORTOR y sin nota; si lo quita, la fila se va
--          (como antes: sin acompañante no hay origen ni nota);
--        · `agregar_acompaniamiento()` → después de poner al acompañante, deja la fila con origen COORDINADOR y la
--          nota. El reintento idempotente (ya figura esa persona) no toca nada.
--      Una jornada con acompañante escrita por el servidor por fuera de la RPC (un administrador con SQL, un
--      fixture) queda con origen COLPORTOR: el servidor ya no distingue ese camino, que el producto no usa.
--   5. Las lecturas del panel toman la nota y el origen de su lugar nuevo, con las mismas firmas y columnas de
--      salida (el panel, front-coordinadores-web#96, no cambia una línea): `jornadas_acompaniadas_de_campania()`
--      (de ahí sale `historial_de_acompaniamientos()`), `jornadas_cerradas_de_colportor()` y
--      `agregar_acompaniamiento()`.
--
-- ## Qué no cambia
--
--   · `acompaniamiento_cargado_por` (0116) sigue en `jornada`: la decisión nombra la nota y su origen. Queda
--     como pendiente de decisión si también debe esconderse.
--   · La auditoría (`acompaniamiento_agregado`) no cambia: nunca llevó el texto de la nota.
--   · `jornada` sigue siendo de solo push (no baja al teléfono) y el teléfono nunca escribió la nota.
--
-- Forward-only: no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. La tabla
-- ----------------------------------------------------------------------------

create table public.jornada_acompaniamiento (
  id            uuid primary key default public.uuid_generate_v7(),
  jornada_id    uuid not null references public.jornada(id) on delete cascade,
  origen        text not null,
  nota          text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid default auth.uid() references public.usuario(id) on delete set null,
  deleted_at    timestamptz,
  sync_version  bigint not null default 0,
  xmin_w        xid8 not null default pg_current_xact_id(),
  constraint jornada_acompaniamiento_jornada_key unique (jornada_id),
  constraint jornada_acompaniamiento_origen_valido
    check (origen in ('COLPORTOR', 'COORDINADOR')),
  -- «Caracteres visibles»: sin espacios ni saltos de línea en los extremos (la RPC los recorta) y hasta 500
  -- caracteres (char_length cuenta caracteres, no bytes). Una nota sin origen COORDINADOR no existe.
  constraint jornada_acompaniamiento_nota_forma
    check (nota is null
           or (origen = 'COORDINADOR'
               and nota ~ '^\S(.*\S)?$'
               and char_length(nota) <= 500))
);

comment on table public.jornada_acompaniamiento is
  'El origen y la nota del acompañamiento de una jornada (0133, backend-supabase#204, decisión de Cristian del '
  '27/10 «Nota visible»): INTERNA, la leen el ADMIN y el coordinador de la campaña; el colportor acompañado no. '
  'Una fila por jornada con acompañante y origen conocido. Lo escribe SOLO el servidor (el trigger de jornada '
  'para lo que marca el teléfono; agregar_acompaniamiento() para lo que carga el coordinador). No viaja por el '
  'sync.';
comment on column public.jornada_acompaniamiento.origen is
  'De dónde salió el acompañamiento: COLPORTOR si lo marcó el colportor en el celular, COORDINADOR si lo cargó '
  'el coordinador o un ADMIN en el panel.';
comment on column public.jornada_acompaniamiento.nota is
  'Nota opcional del coordinador (hasta 500 caracteres, sin datos de clientes: lo dice el aviso del panel). '
  'Solo con origen COORDINADOR.';

create trigger jornada_acompaniamiento_auditoria_insert
  before insert on public.jornada_acompaniamiento
  for each row execute function public.tg_auditoria_insert();
create trigger jornada_acompaniamiento_auditoria_update
  before update on public.jornada_acompaniamiento
  for each row execute function public.tg_auditoria_update();

alter table public.jornada_acompaniamiento enable row level security;
revoke all on public.jornada_acompaniamiento from anon, authenticated;
grant select on public.jornada_acompaniamiento to authenticated;
grant all on public.jornada_acompaniamiento to service_role;

-- Quién puede leer la fila de una jornada: el ADMIN, y quien coordina una campaña en la que el dueño de la
-- jornada estaba inscripto ese instante (desde el alta, antes de la baja, fuera de los huecos y dentro de las
-- fechas de la campaña: la misma ventana de las lecturas del panel). SECURITY DEFINER porque el coordinador no
-- lee `jornada` por RLS. Usa auth.uid() y no recibe al usuario; una jornada inexistente y una ajena dan lo mismo.
create function public.puede_leer_el_acompaniamiento(p_jornada_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.tiene_rol('ADMIN')
      or (public.tiene_rol('COORDINADOR')
          and exists (
            select 1
              from public.jornada j
              join public.campania_colportor i on i.usuario_id = j.colportor_id
              join public.campania c on c.id = i.campania_id
             where j.id = p_jornada_id
               and c.coordinador_id = auth.uid()
               and c.deleted_at is null
               and public.inscripcion_cubre_el_instante(i.created_at, i.deleted_at, i.tramos_afuera, j.inicio)
               and public.hoy_montevideo(j.inicio) >= c.fecha_inicio
               and public.hoy_montevideo(j.inicio) <= coalesce(c.fecha_fin, 'infinity'::date)))
$$;

comment on function public.puede_leer_el_acompaniamiento(uuid) is
  'Interna de la RLS de jornada_acompaniamiento (0133, #204): si quien llama es ADMIN o coordina la campaña en '
  'la que estaba inscripto el dueño de la jornada ese día. Una jornada que no existe o es ajena da false.';

revoke all on function public.puede_leer_el_acompaniamiento(uuid) from public, anon, authenticated, service_role;
grant execute on function public.puede_leer_el_acompaniamiento(uuid) to authenticated;

-- LEE: el ADMIN y quien coordina la campaña. Sin políticas de escritura: no escribe nadie con JWT.
create policy jornada_acompaniamiento_select on public.jornada_acompaniamiento
  for select to authenticated
  using ((select public.puede_leer_el_acompaniamiento(jornada_id)));

-- ----------------------------------------------------------------------------
-- 2. Se mueve lo que había, sin perder nada
-- ----------------------------------------------------------------------------

insert into public.jornada_acompaniamiento (jornada_id, origen, nota)
select j.id, j.acompaniamiento_origen, j.acompaniamiento_nota
  from public.jornada j
 where j.acompaniante_id is not null
   and j.acompaniamiento_origen is not null;

do $$
declare
  v_antes   bigint;
  v_despues bigint;
  v_notas   bigint;
begin
  select count(*) into v_antes from public.jornada
   where acompaniante_id is not null and acompaniamiento_origen is not null;
  select count(*) into v_despues from public.jornada_acompaniamiento;
  if v_antes <> v_despues then
    raise exception '0133: se movieron % acompañamientos y había %. No se sigue.', v_despues, v_antes;
  end if;
  select count(*) into v_notas
    from public.jornada j
    join public.jornada_acompaniamiento d on d.jornada_id = j.id
   where d.origen is distinct from j.acompaniamiento_origen
      or d.nota is distinct from j.acompaniamiento_nota;
  if v_notas <> 0 then
    raise exception '0133: % acompañamientos cambiaron de origen o de nota al moverse. No se sigue.', v_notas;
  end if;
end;
$$;

-- ----------------------------------------------------------------------------
-- 3. Las lecturas: misma firma y mismas columnas, desde el lugar nuevo
-- ----------------------------------------------------------------------------

-- Sin permiso a propósito: la llaman solo las funciones que lo piden antes.
create or replace function public.jornadas_acompaniadas_de_campania(p_campania_id uuid)
returns table (jornada_id uuid, colportor_id uuid, dia date, horas numeric, en_curso boolean,
               acompaniante_id uuid, acompaniamiento_origen text, acompaniamiento_nota text)
language sql
stable
security definer
set search_path = ''
as $$
  select j.id,
         j.colportor_id,
         public.hoy_montevideo(j.inicio),
         case when j.fin is null then null
              else round(extract(epoch from (j.fin - j.inicio))::numeric / 3600, 2) end,
         (j.fin is null),
         j.acompaniante_id,
         d.origen,
         d.nota
    from public.campania c
    join public.campania_colportor i on i.campania_id = c.id
    join public.jornada j on j.colportor_id = i.usuario_id
    left join public.jornada_acompaniamiento d on d.jornada_id = j.id and d.deleted_at is null
   where c.id = p_campania_id
     and c.deleted_at is null
     and j.deleted_at is null
     and j.acompaniante_id is not null
     and public.inscripcion_cubre_el_instante(i.created_at, i.deleted_at, i.tramos_afuera, j.inicio)
     and public.hoy_montevideo(j.inicio) >= c.fecha_inicio
     and public.hoy_montevideo(j.inicio) <= coalesce(c.fecha_fin, 'infinity'::date)
$$;

comment on function public.jornadas_acompaniadas_de_campania(uuid) is
  'Interna (0043, backend-supabase#97; 0100, #140; 0133, #204): las jornadas vivas con acompañante de los '
  'colportores inscriptos en la campaña (desde el alta, antes de la baja y fuera de los huecos de las vueltas, '
  'en sus fechas, día de Montevideo), abiertas incluidas (horas null), con el origen y la nota que salen de '
  'jornada_acompaniamiento (null si es anterior a la 0100). Sin permiso: la usan acompaniamientos_por_colportor() '
  'e historial_de_acompaniamientos(), que lo piden antes.';

create or replace function public.jornadas_cerradas_de_colportor(p_campania_id uuid, p_colportor_id uuid)
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
           d.origen,
           d.nota,
           j.acompaniamiento_cargado_por,
           car.nombre,
           car.apellido
      from public.campania_colportor i
      join public.jornada j on j.colportor_id = i.usuario_id
      left join public.usuario aco on aco.id = j.acompaniante_id
      left join public.usuario car on car.id = j.acompaniamiento_cargado_por
      left join public.jornada_acompaniamiento d on d.jornada_id = j.id and d.deleted_at is null
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
  'Vista 33, HU-JOR-004 (0043, backend-supabase#97; 0100, #140; 0116, #173; 0133, #204): las jornadas CERRADAS '
  'de p_colportor_id en la campaña (fechas de la campaña, desde el alta, antes de la baja y fuera de los '
  'huecos de la inscripción, día de Montevideo), la más nueva primero, con sus horas, quién la acompañó '
  '(null si nadie todavía), el origen y la nota (de jornada_acompaniamiento: internas, solo coordinación) y '
  'quién cargó el acompañamiento en el panel (acompaniamiento_cargado_por y su nombre y apellido; null si lo '
  'marcó el colportor o es anterior a la 0116): de ahí elige el coordinador a cuál agregar su acompañamiento. '
  'Un colportor que no es de la campaña (o null) da la lista vacía. Una campaña terminada se lee. Errores: '
  '42501 sin permiso; CZ001 campaña inexistente.';

-- ----------------------------------------------------------------------------
-- 4. Agregar un acompañamiento: la nota y el origen van a la tabla nueva
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

    -- Quién lo cargó (0116, #173): quien llama, que es el coordinador de la campaña o un ADMIN. Lo pone el
    -- servidor con auth.uid() y el cliente no lo elige.
    update public.jornada j
       set acompaniante_id = v_acomp,
           acompaniamiento_cargado_por = v_yo
     where j.id = v_jornada.id;

    -- El origen y la nota (0133, #204): en la tabla interna, que no lee el colportor. El trigger de jornada
    -- acaba de dejar la fila con origen COLPORTOR (cambió el acompañante); acá pasa a COORDINADOR con la nota.
    insert into public.jornada_acompaniamiento (jornada_id, origen, nota)
    values (v_jornada.id, 'COORDINADOR', v_nota)
    on conflict on constraint jornada_acompaniamiento_jornada_key do update
      set origen = excluded.origen,
          nota = excluded.nota,
          deleted_at = null;
    v_origen := 'COORDINADOR';

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
    select d.nota, d.origen into v_nota, v_origen
      from public.jornada_acompaniamiento d
     where d.jornada_id = v_jornada.id and d.deleted_at is null;
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
  'Vista 33, HU-JOR-004 (0043, backend-supabase#97; 0073, #136; 0100 y 0103, #140; 0116, #173; 0133, #204): el '
  'coordinador de la campaña (o un ADMIN) registra el acompañamiento de una jornada ya cerrada: el suyo («Yo», '
  'sin p_acompaniante_id) o el de otro colportor inscripto en la campaña, con una nota opcional (hasta 500 '
  'caracteres). Deja jornada.acompaniante_id y acompaniamiento_cargado_por = quien llama, el origen COORDINADOR '
  'y la nota en jornada_acompaniamiento (internas: no las lee el colportor), y el evento '
  'acompaniamiento_agregado en audit_log. Idempotente (ya_estaba, sin segundo registro ni cambio de nota) si '
  'ya figuraba esa misma persona; si la acompañó otra, JO003 y no se pisa. Una campaña terminada se acepta '
  'hasta 15 días después de su fin (0020). Errores: 42501 sin permiso; CZ001 campaña inexistente; CZ011 '
  'campaña terminada hace más de 15 días; 22023 sin jornada o nota de más de 500 caracteres; JO001 jornada '
  'que no es de un colportor de la campaña; JO002 jornada abierta; JO003 ya acompañada por otra persona; '
  'JO004 la jornada es de quien se quiere anotar como acompañante; JO005 el colportor elegido no está '
  'inscripto en la campaña.';

-- ----------------------------------------------------------------------------
-- 5. Quién mantiene la tabla cuando es el teléfono el que marca
-- ----------------------------------------------------------------------------

-- El BEFORE de la 0100/0116 ya no toca el origen ni la nota (no existen más en jornada): queda quién cargó. Un
-- cliente (authenticated, anon) no lo elige: si marca o cambia al acompañante, se va; si no lo toca, se conserva.
create or replace function public.tg_jornada_acompaniamiento_servidor()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user in ('authenticated', 'anon') then
    if tg_op = 'INSERT' or new.acompaniante_id is distinct from old.acompaniante_id then
      new.acompaniamiento_cargado_por := null;
    else
      new.acompaniamiento_cargado_por := old.acompaniamiento_cargado_por;
    end if;
  elsif new.acompaniante_id is null then
    -- También el servidor: sin acompañante no hay quien cargó (el ON DELETE SET NULL de la FK pasa por acá).
    new.acompaniamiento_cargado_por := null;
  end if;
  return new;
end;
$$;

comment on function public.tg_jornada_acompaniamiento_servidor() is
  'BEFORE INSERT/UPDATE de jornada (0100, #140; 0116, #173; 0133, #204): quien cargó el acompañamiento es del '
  'servidor. Un cliente que marca o cambia al acompañante lo deja en null; si no lo toca, se conserva. Sin '
  'acompañante no hay quien cargó. El origen y la nota viven en jornada_acompaniamiento.';

-- AFTER (SECURITY DEFINER: el colportor no puede escribir la tabla). Con acompañante nuevo o cambiado, la fila
-- queda con origen COLPORTOR y sin nota (lo marcó el teléfono; si lo cambió, la nota del coordinador se va, como
-- antes). agregar_acompaniamiento() la pasa a COORDINADOR enseguida. Sin acompañante, la fila se borra: sin
-- acompañante no hay origen ni nota.
create function public.tg_jornada_acompaniamiento_detalle()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.acompaniante_id is null then
    delete from public.jornada_acompaniamiento d where d.jornada_id = new.id;
  else
    insert into public.jornada_acompaniamiento (jornada_id, origen, nota)
    values (new.id, 'COLPORTOR', null)
    on conflict (jornada_id) do update
      set origen = 'COLPORTOR', nota = null, deleted_at = null;
  end if;
  return null;
end;
$$;

comment on function public.tg_jornada_acompaniamiento_detalle() is
  'AFTER INSERT/UPDATE del acompañante de jornada (0133, #204): deja jornada_acompaniamiento con origen COLPORTOR '
  'y sin nota cuando se marca o cambia al acompañante, y la borra cuando se quita. Interna.';

revoke all on function public.tg_jornada_acompaniamiento_detalle() from public, anon, authenticated, service_role;

create trigger jornada_acompaniamiento_detalle_insert
  after insert on public.jornada
  for each row
  when (new.acompaniante_id is not null)
  execute function public.tg_jornada_acompaniamiento_detalle();

create trigger jornada_acompaniamiento_detalle_update
  after update of acompaniante_id on public.jornada
  for each row
  when (new.acompaniante_id is distinct from old.acompaniante_id)
  execute function public.tg_jornada_acompaniamiento_detalle();

-- ----------------------------------------------------------------------------
-- 6. `jornada` pierde las dos columnas
-- ----------------------------------------------------------------------------

alter table public.jornada
  drop constraint jornada_acompaniamiento_cargado_por_con_origen,
  drop constraint jornada_acompaniamiento_nota_forma,
  drop constraint jornada_acompaniamiento_origen_con_acompaniante,
  drop constraint jornada_acompaniamiento_origen_valido;

alter table public.jornada
  drop column acompaniamiento_origen,
  drop column acompaniamiento_nota;

-- Quien cargó el acompañamiento solo existe con acompañante (antes lo ataba al origen COORDINADOR).
alter table public.jornada
  add constraint jornada_acompaniamiento_cargado_por_con_acompaniante
    check (acompaniamiento_cargado_por is null or acompaniante_id is not null);

update sync.entidad
   set columnas_servidor = array_remove(array_remove(columnas_servidor, 'acompaniamiento_origen'),
                                        'acompaniamiento_nota')
 where nombre = 'jornada';
