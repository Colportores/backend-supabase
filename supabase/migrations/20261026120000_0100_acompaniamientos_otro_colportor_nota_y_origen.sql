-- ============================================================================
-- 0100 · Acompañamientos: otro colportor, nota y origen, 15 días tras el cierre, tramo afuera y
--        «contado desde» (backend-supabase#140, seguimiento de #97 / 0043, HU-JOR-004, vista 33)
--
-- Origen: las cinco decisiones de Cristian del 23/10 sobre el PR #117 (backend-supabase#97) y sobre
-- front-coordinadores-web#75, que dejaron en #140 lo que le faltaba a la 0043:
--
--   «Quién acompaña»  «Sí, de la misma campaña»: «Yo» u «Otro colportor», elegido entre los inscriptos
--                     vivos de la misma campaña; el historial muestra su nombre.
--   «Nota acomp.»     «Nota y origen»: dos datos de la jornada que pone el servidor: de dónde salió el
--                     acompañamiento (lo marcó el colportor en el celular o lo cargó el coordinador en el
--                     panel) y una nota opcional corta que escribe el coordinador, sin datos de clientes.
--   «Acomp. tarde»    «15 días, como las ventas»: se puede registrar hasta 15 días después del fin de la
--                     campaña (0020); después, CZ011 como hoy. Sigue sin pisar uno ya registrado (JO003) ni
--                     anotarse en su propia jornada (JO004).
--   «Jornada camp.»   «Fechas y reactivación»: la campaña de una jornada se sigue deduciendo por las
--                     fechas; para cerrar el hueco de la reactivación (0028) la inscripción guarda desde
--                     cuándo volvió y las jornadas del tiempo en que estuvo afuera no cuentan en esa campaña.
--   «Días acomp.»     «Desde que se sumó»: «Nunca» y debajo «20 días desde que se sumó»; a quien está
--                     desde el principio, «50 días desde el inicio».
--
-- ## Qué cambia
--
--   1. `agregar_acompaniamiento(p_campania_id, p_jornada_id, p_acompaniante_id default null,
--      p_nota default null)`. Sin `p_acompaniante_id` (o con el de quien llama) es «Yo», como antes. Con el
--      de otra persona, tiene que ser un colportor INSCRIPTO VIVO en la campaña de la jornada (`JO005`) y
--      distinto del dueño de la jornada (`JO004`, el mismo código que «tu propia jornada»). Nada de esto
--      cambia el resto: JO001 (la jornada no es de la campaña), JO002 (sigue abierta), JO003 (ya la
--      acompañó otra persona: nunca se pisa) y CZ011.
--      La firma cambia (dos parámetros opcionales al final y dos columnas al final del resultado), así que
--      se hace `drop function` de la de dos argumentos y `create` de la nueva: con `create or replace`
--      quedarían las dos funciones y PostgREST no sabría a cuál llamar. Un cliente que manda solo
--      `{p_campania_id, p_jornada_id}` sigue andando igual.
--   2. `jornada.acompaniamiento_origen` (`COLPORTOR` | `COORDINADOR`) y `jornada.acompaniamiento_nota`
--      (opcional, hasta 280 caracteres, sin espacios en los extremos). Las dos son del servidor
--      (`sync.entidad.columnas_servidor` de `jornada`: el push las descarta) y las pone un trigger y la
--      RPC según el camino:
--        · el teléfono marca «me acompañaron» (push o INSERT/UPDATE con JWT de cliente) → `COLPORTOR`,
--          sin nota; si el teléfono cambia o quita al acompañante, el origen se recalcula y la nota se va;
--        · `agregar_acompaniamiento()` → `COORDINADOR`, con la nota que escribió el coordinador;
--        · sin acompañante no hay origen ni nota (CHECK y trigger), y la nota exige origen `COORDINADOR`.
--      Las jornadas que ya tenían acompañante antes de esta migración quedan con origen `null`: el dato no
--      existía y no se inventa («no se sabe»; el panel no muestra el origen).
--      `historial_de_acompaniamientos()`, `jornadas_cerradas_de_colportor()` y `agregar_acompaniamiento()`
--      devuelven las dos columnas. `acompaniamientos_por_colportor()` es por colportor y no las lleva.
--   3. La gracia de 15 días: `agregar_acompaniamiento()` acepta una campaña terminada si
--      `escritura_dentro_de_plazo(fecha_fin)` (0020) lo permite, la MISMA función que usan las ventas: el
--      número 15 vive en un solo lugar. El día 15 se acepta (hasta las 23:59 de Montevideo), el 16 da CZ011.
--      Las lecturas ya leían campañas terminadas, sin tope.
--   4. El tramo afuera: `campania_colportor.tramos_afuera` (`tstzrange[]`, vacío por defecto) guarda cada
--      hueco «de la baja a la vuelta». Lo escribe un trigger cuando la inscripción se REACTIVA (0028,
--      cualquier camino: `inscribir_colportor()` o el servidor): agrega `[deleted_at, now())`. Es un
--      arreglo y no un par de columnas porque una inscripción puede darse de baja y volver más de una vez,
--      y cada hueco tiene que seguir fuera. Un cliente (authenticated, anon) no lo escribe. Las jornadas
--      que empezaron dentro de un hueco no cuentan en esa campaña: lo único que cambia es la ventana de
--      «la jornada es de esta campaña» (`inscripcion_cubre_el_instante()`), que comparten las cuatro RPC.
--      Las reactivaciones anteriores a esta migración no dejaron huella y no se reconstruyen (los datos de
--      hoy son simulados).
--   5. «Días sin acompañar» de quien nunca fue acompañado: `contado_desde` pasa a ser
--      `greatest(inicio de la campaña, día en que se inscribió o volvió)` y `dias_sin_acompaniar` se cuenta
--      desde ahí. `ultimo_dia` sigue en `null` («Nunca»). El panel rotula según `contado_desde`: si es el
--      inicio de la campaña, «N días desde el inicio»; si es posterior, «N días desde que se sumó».
--
-- ## Auditoría
--
-- El evento `acompaniamiento_agregado` (0073) suma al detalle `acompaniante_id` (quién acompañó; el actor
-- es quien lo cargó) y `con_nota` (si llevó nota). La nota NO se copia al registro: es texto libre y la
-- regla de la auditoría es llevar ids, fechas y números (decisión de #136, P2).
--
-- ## Para otros repos
--
--   · front-coordinadores-web (#63, vista 33): `POST /rest/v1/rpc/agregar_acompaniamiento
--     { p_campania_id, p_jornada_id, p_acompaniante_id?, p_nota? }`. «Yo» = no mandar `p_acompaniante_id`.
--     «Otro colportor» = los inscriptos de la campaña (la lista que ya tiene el panel). La respuesta y las
--     dos lecturas de jornadas traen `acompaniamiento_origen` y `acompaniamiento_nota`. Avisos nuevos:
--     JO005 («ese colportor no está en la campaña»), JO004 con otro texto, y CZ011 solo pasados los 15
--     días. «Nunca» = `ultimo_dia` null; el rótulo de abajo según `contado_desde`.
--   · Los 280 caracteres de la nota los puse yo: el diseño no dice un tope (pendiente del PR, mapa §2).
--   · docs-organizacion: esquema-datos.md (jornada, campania_colportor), HU-JOR-004 y el contrato (columnas
--     de servidor de `jornada`). Issue de seguimiento en ese repo.
--   · front-colportores-mobile: nada. `jornada` es de solo push (no baja al teléfono) y la nota no viaja
--     en el push; un `server_row` de conflicto sí las incluye, y el pull de `campania_colportor` suma la
--     clave `tramos_afuera` (como pasó con las columnas de 0067).
--
-- Forward-only: no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Columnas nuevas
-- ----------------------------------------------------------------------------

alter table public.jornada
  add column acompaniamiento_origen text,
  add column acompaniamiento_nota   text;

alter table public.jornada
  add constraint jornada_acompaniamiento_origen_valido
    check (acompaniamiento_origen in ('COLPORTOR', 'COORDINADOR')),
  add constraint jornada_acompaniamiento_origen_con_acompaniante
    check (acompaniamiento_origen is null or acompaniante_id is not null),
  -- «Caracteres visibles»: sin espacios ni saltos de línea en los extremos (la RPC los recorta) y hasta
  -- 280 caracteres (char_length cuenta caracteres, no bytes). Una nota sin origen COORDINADOR no existe.
  add constraint jornada_acompaniamiento_nota_forma
    check (acompaniamiento_nota is null
           or (acompaniamiento_origen = 'COORDINADOR'
               and acompaniamiento_nota ~ '^\S(.*\S)?$'
               and char_length(acompaniamiento_nota) <= 280));

comment on column public.jornada.acompaniamiento_origen is
  'De dónde salió el acompañamiento (0100, #140): COLPORTOR si lo marcó el colportor en el celular, '
  'COORDINADOR si lo cargó el coordinador en el panel. null = sin acompañante, o una jornada anterior '
  'a la 0100 (no se sabe). Lo pone el servidor; el push lo descarta.';
comment on column public.jornada.acompaniamiento_nota is
  'Nota opcional del coordinador sobre el acompañamiento (0100, #140): hasta 280 caracteres, sin datos de '
  'clientes (lo dice el aviso del panel; no se puede validar). Solo con origen COORDINADOR. Lo pone el '
  'servidor; el push la descarta.';

alter table public.campania_colportor
  add column tramos_afuera tstzrange[] not null default '{}';

comment on column public.campania_colportor.tramos_afuera is
  'Los huecos de la inscripción (0100, #140): cada vez que se reactiva (0028) se agrega [baja, vuelta). '
  'Las jornadas que empezaron adentro de un hueco no cuentan en esta campaña. Lo escribe el trigger '
  'campania_colportor_tramos_afuera; un cliente no.';

-- El push no las escribe (contrato §5.4): se descartan en silencio.
update sync.entidad
   set columnas_servidor = columnas_servidor || array['acompaniamiento_origen', 'acompaniamiento_nota']
 where nombre = 'jornada';

-- ----------------------------------------------------------------------------
-- 2. Triggers: el origen y la nota los decide el servidor; el hueco, la reactivación
-- ----------------------------------------------------------------------------

-- Un cliente (authenticated, anon: el push corre INVOKER, o un INSERT/UPDATE por la API) no elige el origen
-- ni la nota: si marca o cambia al acompañante, es COLPORTOR y sin nota; si no lo toca, lo que había. Desde
-- una función SECURITY DEFINER (agregar_acompaniamiento()) o el servidor, current_user es otro y vale lo
-- que se escribió. Se mira current_user y no auth.uid(), como 0053: adentro del RPC el JWT sigue puesto.
create function public.tg_jornada_acompaniamiento_servidor()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user in ('authenticated', 'anon') then
    if tg_op = 'INSERT' or new.acompaniante_id is distinct from old.acompaniante_id then
      new.acompaniamiento_origen := case when new.acompaniante_id is not null then 'COLPORTOR' end;
      new.acompaniamiento_nota := null;
    else
      new.acompaniamiento_origen := old.acompaniamiento_origen;
      new.acompaniamiento_nota := old.acompaniamiento_nota;
    end if;
  elsif new.acompaniante_id is null then
    -- También el servidor: sin acompañante no hay origen ni nota (el ON DELETE SET NULL de la FK pasa por acá).
    new.acompaniamiento_origen := null;
    new.acompaniamiento_nota := null;
  end if;
  return new;
end;
$$;

comment on function public.tg_jornada_acompaniamiento_servidor() is
  'BEFORE INSERT/UPDATE de jornada (0100, #140): el origen y la nota del acompañamiento son del servidor. '
  'Un cliente que marca o cambia al acompañante deja origen COLPORTOR y sin nota; si no lo toca, se '
  'conserva lo que había. Sin acompañante no hay origen ni nota.';

revoke all on function public.tg_jornada_acompaniamiento_servidor() from public, anon, authenticated;

create trigger jornada_acompaniamiento_servidor
  before insert or update on public.jornada
  for each row execute function public.tg_jornada_acompaniamiento_servidor();

-- La reactivación de una inscripción deja el hueco. now() es el instante de la transacción que reactiva:
-- una jornada que empezó antes de él (y después de la baja) no cuenta; una posterior, sí.
create function public.tg_campania_colportor_tramos_afuera()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if current_user in ('authenticated', 'anon') then
      new.tramos_afuera := '{}';
    end if;
    return new;
  end if;

  if current_user in ('authenticated', 'anon') then
    new.tramos_afuera := old.tramos_afuera;
  end if;

  -- Si la baja y la vuelta caen en el mismo instante no hay hueco que guardar.
  if old.deleted_at is not null and new.deleted_at is null and old.deleted_at < now() then
    new.tramos_afuera := new.tramos_afuera || tstzrange(old.deleted_at, now(), '[)');
  end if;
  return new;
end;
$$;

comment on function public.tg_campania_colportor_tramos_afuera() is
  'BEFORE INSERT/UPDATE de campania_colportor (0100, #140): al reactivar una inscripción (0028) agrega '
  '[baja, vuelta) a tramos_afuera. Un cliente (authenticated, anon) no escribe la columna.';

revoke all on function public.tg_campania_colportor_tramos_afuera() from public, anon, authenticated;

create trigger campania_colportor_tramos_afuera
  before insert or update on public.campania_colportor
  for each row execute function public.tg_campania_colportor_tramos_afuera();

-- ----------------------------------------------------------------------------
-- 3. Interna: la jornada de un instante es de esta inscripción
-- ----------------------------------------------------------------------------

-- La única definición de «esta jornada es de esta campaña» del lado de la inscripción (las fechas de la
-- campaña se miran aparte): desde que el colportor se inscribió, hasta su baja si la hubo, y fuera de los
-- huecos de las bajas y vueltas anteriores. Pura.
create function public.inscripcion_cubre_el_instante(p_alta timestamptz, p_baja timestamptz,
                                                     p_afuera tstzrange[], p_instante timestamptz)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_instante >= p_alta
     and (p_baja is null or p_instante < p_baja)
     and not exists (select 1 from unnest(p_afuera) t where t @> p_instante)
$$;

comment on function public.inscripcion_cubre_el_instante(timestamptz, timestamptz, tstzrange[], timestamptz) is
  'Interna (0100, #140): si una jornada que empezó en p_instante es de la inscripción: desde el alta, antes '
  'de la baja si la hubo y fuera de los huecos (tramos_afuera). Las fechas de la campaña se miran aparte.';

revoke all on function public.inscripcion_cubre_el_instante(timestamptz, timestamptz, tstzrange[], timestamptz)
  from public, anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 4. Las funciones de 0043, con la ventana nueva y con el origen y la nota
-- ----------------------------------------------------------------------------

drop function public.jornadas_acompaniadas_de_campania(uuid);
drop function public.historial_de_acompaniamientos(uuid, uuid);
drop function public.jornadas_cerradas_de_colportor(uuid, uuid);
drop function public.agregar_acompaniamiento(uuid, uuid);

-- Sin permiso a propósito: la llaman solo las funciones de abajo, que lo piden antes.
create function public.jornadas_acompaniadas_de_campania(p_campania_id uuid)
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
         j.acompaniamiento_origen,
         j.acompaniamiento_nota
    from public.campania c
    join public.campania_colportor i on i.campania_id = c.id
    join public.jornada j on j.colportor_id = i.usuario_id
   where c.id = p_campania_id
     and c.deleted_at is null
     and j.deleted_at is null
     and j.acompaniante_id is not null
     and public.inscripcion_cubre_el_instante(i.created_at, i.deleted_at, i.tramos_afuera, j.inicio)
     and public.hoy_montevideo(j.inicio) >= c.fecha_inicio
     and public.hoy_montevideo(j.inicio) <= coalesce(c.fecha_fin, 'infinity'::date)
$$;

comment on function public.jornadas_acompaniadas_de_campania(uuid) is
  'Interna (0043, backend-supabase#97; 0100, #140): las jornadas vivas con acompañante de los colportores '
  'inscriptos en la campaña (desde el alta, antes de la baja y fuera de los huecos de las vueltas, en sus '
  'fechas, día de Montevideo), abiertas incluidas (horas null), con el origen y la nota. Sin permiso: la '
  'usan acompaniamientos_por_colportor() e historial_de_acompaniamientos(), que lo piden antes.';

revoke all on function public.jornadas_acompaniadas_de_campania(uuid)
  from public, anon, authenticated, service_role;

-- La tabla de la vista 33. Misma firma que en 0043: cambia de dónde sale `contado_desde`.
create or replace function public.acompaniamientos_por_colportor(p_campania_id uuid)
returns table (colportor_id uuid, nombre text, apellido text, ciudad_id uuid, ciudad_nombre text,
               acompaniamientos integer, ultimo_dia date, dias_sin_acompaniar integer,
               contado_desde date)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_motivo   text;
  v_campania public.campania;
  v_hoy      date := public.hoy_montevideo();
begin
  -- El permiso, antes de mirar nada más. Una campaña terminada se lee (el historial se consulta
  -- también al cierre); una por empezar, también.
  v_motivo := public.motivo_mapa_de_campania(p_campania_id);
  if v_motivo = 'SIN_PERMISO' then
    raise exception 'Solo el coordinador de la campaña o un administrador puede ver sus acompañamientos. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_motivo is distinct from 'CAMPANIA_TERMINADA' then
    perform public.lanzar_motivo_mapa(v_motivo);
  end if;

  select * into v_campania from public.campania c where c.id = p_campania_id;

  return query
    with acompaniadas as (
      select h.colportor_id as colp,
             count(*)::integer as total,
             max(h.dia) as ultimo
        from public.jornadas_acompaniadas_de_campania(p_campania_id) h
       group by h.colportor_id
    )
    select i.usuario_id,
           usr.nombre,
           usr.apellido,
           ci.ciudad_id,
           ciu.nombre,
           coalesce(a.total, 0),
           a.ultimo,
           greatest(v_hoy - coalesce(a.ultimo, d.desde), 0),
           coalesce(a.ultimo, d.desde)
      from public.campania_colportor i
      join public.usuario usr on usr.id = i.usuario_id
      -- Quien nunca fue acompañado se cuenta desde lo más tarde entre el inicio de la campaña y el día en
      -- que se sumó (o en que volvió, si estuvo afuera): una inscripción que vuelve arranca de nuevo.
      cross join lateral (
        select greatest(
                 v_campania.fecha_inicio,
                 public.hoy_montevideo(
                   coalesce((select max(upper(t)) from unnest(i.tramos_afuera) t), i.created_at))) as desde
      ) d
      -- La ciudad es la de la zona actual (decisión del 21/10, «Ciudad colp.»); sin zona, null.
      left join public.zona z on z.id = i.zona_id and z.deleted_at is null
      left join public.campania_ciudad ci on ci.id = z.campania_ciudad_id and ci.deleted_at is null
      left join public.ciudad ciu on ciu.id = ci.ciudad_id
      left join acompaniadas a on a.colp = i.usuario_id
     where i.campania_id = p_campania_id
       and i.deleted_at is null
     order by 8 desc, usr.apellido, usr.nombre, i.usuario_id;
end;
$$;

comment on function public.acompaniamientos_por_colportor(uuid) is
  'Vista 33, HU-JOR-004 (0043, backend-supabase#97; 0100, #140): por colportor inscripto (vivo) de la '
  'campaña, cuántas jornadas acompañadas tiene, el día del último y los días corridos sin acompañar '
  '(desde el último o, si nunca, desde contado_desde: lo más tarde entre el inicio de la campaña y el día '
  'en que se sumó o volvió; sin umbral). Las jornadas del tiempo que estuvo afuera no cuentan. Orden: más '
  'días sin acompañar primero. Una campaña terminada se lee. Errores: 42501 sin permiso; CZ001 campaña '
  'inexistente. Solo totales: ni clientes ni ventas.';

create function public.historial_de_acompaniamientos(p_campania_id uuid,
                                                     p_colportor_id uuid default null)
returns table (jornada_id uuid, colportor_id uuid, nombre text, apellido text, dia date,
               horas numeric, en_curso boolean, acompaniante_id uuid,
               acompaniante_nombre text, acompaniante_apellido text,
               acompaniamiento_origen text, acompaniamiento_nota text)
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
           h.acompaniamiento_nota
      from public.jornadas_acompaniadas_de_campania(p_campania_id) h
      join public.usuario usr on usr.id = h.colportor_id
      join public.usuario aco on aco.id = h.acompaniante_id
     where p_colportor_id is null or h.colportor_id = p_colportor_id
     order by h.dia desc, h.jornada_id desc;
end;
$$;

comment on function public.historial_de_acompaniamientos(uuid, uuid) is
  'Vista 33, HU-JOR-004 (0043, backend-supabase#97; 0100, #140): las jornadas acompañadas de la campaña '
  '(de p_colportor_id, o de todos si es null), la más nueva primero: día de Montevideo, horas de la '
  'jornada (null si sigue abierta), quién acompañó, de dónde salió el dato (acompaniamiento_origen: '
  'COLPORTOR | COORDINADOR | null si es anterior a la 0100) y la nota. Una campaña terminada se lee. Un '
  'colportor que no es de la campaña da la lista vacía. Errores: 42501 sin permiso; CZ001 campaña '
  'inexistente.';

revoke all on function public.historial_de_acompaniamientos(uuid, uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.historial_de_acompaniamientos(uuid, uuid) to authenticated;

create function public.jornadas_cerradas_de_colportor(p_campania_id uuid, p_colportor_id uuid)
returns table (jornada_id uuid, dia date, horas numeric, acompaniante_id uuid,
               acompaniante_nombre text, acompaniante_apellido text,
               acompaniamiento_origen text, acompaniamiento_nota text)
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
           j.acompaniamiento_nota
      from public.campania_colportor i
      join public.jornada j on j.colportor_id = i.usuario_id
      left join public.usuario aco on aco.id = j.acompaniante_id
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
  'Vista 33, HU-JOR-004 (0043, backend-supabase#97; 0100, #140): las jornadas CERRADAS de p_colportor_id en '
  'la campaña (fechas de la campaña, desde el alta, antes de la baja y fuera de los huecos de la '
  'inscripción, día de Montevideo), la más nueva primero, con sus horas, quién la acompañó (null si nadie '
  'todavía), el origen y la nota: de ahí elige el coordinador a cuál agregar su acompañamiento. Un '
  'colportor que no es de la campaña da la lista vacía. Una campaña terminada se lee. Errores: 42501 sin '
  'permiso; CZ001 campaña inexistente.';

revoke all on function public.jornadas_cerradas_de_colportor(uuid, uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.jornadas_cerradas_de_colportor(uuid, uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 5. Agregar un acompañamiento: yo u otro colportor, con nota, hasta 15 días después del cierre
-- ----------------------------------------------------------------------------

create function public.agregar_acompaniamiento(p_campania_id uuid, p_jornada_id uuid,
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
  if char_length(v_nota) > 280 then
    raise exception 'La nota admite hasta 280 caracteres y esta tiene %. Acortala; no pongas datos de clientes.',
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
           acompaniamiento_nota = v_nota
     where j.id = v_jornada.id;
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
  'Vista 33, HU-JOR-004 (0043, backend-supabase#97; 0073, #136; 0100, #140): el coordinador de la campaña '
  '(o un ADMIN) registra el acompañamiento de una jornada ya cerrada: el suyo («Yo», sin p_acompaniante_id) '
  'o el de otro colportor inscripto en la campaña, con una nota opcional (hasta 280 caracteres). Deja '
  'jornada.acompaniante_id, acompaniamiento_origen = COORDINADOR y la nota, y el evento '
  'acompaniamiento_agregado en audit_log. Idempotente (ya_estaba, sin segundo registro ni cambio de nota) si '
  'ya figuraba esa misma persona; si la acompañó otra, JO003 y no se pisa. Una campaña terminada se acepta '
  'hasta 15 días después de su fin (0020). Errores: 42501 sin permiso; CZ001 campaña inexistente; CZ011 '
  'campaña terminada hace más de 15 días; 22023 sin jornada o nota de más de 280 caracteres; JO001 jornada '
  'que no es de un colportor de la campaña; JO002 jornada abierta; JO003 ya acompañada por otra persona; '
  'JO004 la jornada es de quien se quiere anotar como acompañante; JO005 el colportor elegido no está '
  'inscripto en la campaña.';

revoke all on function public.agregar_acompaniamiento(uuid, uuid, uuid, text)
  from public, anon, authenticated, service_role;
grant execute on function public.agregar_acompaniamiento(uuid, uuid, uuid, text) to authenticated;
