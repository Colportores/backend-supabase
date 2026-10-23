-- ============================================================================
-- 0063 · El departamento de cada ciudad: columna, carga de Montevideo y lectura
--        (backend-supabase#92, HU-ADM-005, HU-CAM-008, C14)
--
-- Origen: el cambio de requisitos del 21/10 (reunión del 05/10, docs#69, C14 y C15). El panel agrupa las
-- ciudades por departamento y filtra departamento -> ciudad (vista 31 «Inicio Vista Rápida», HU-CAM-008;
-- reportes HU-REP-001 y HU-REP-002), y el buscador de «+ Agregar ciudad» de la vista 24 muestra cada
-- ciudad con su departamento: Marta busca Salto y hay dos «San José».
--
-- Decisión de Cristian (21/10), «Departamento»
-- (https://github.com/Colportores/backend-supabase/issues/92#issuecomment-6323690658): «Sí, cada ciudad guarda su
-- departamento». Un solo campo sirve a dos pedidos: backend-supabase#68 (mapas offline por departamento)
-- lo reutiliza. Ya figuraba en esquema-datos.md y en HU-ADM-005.
--
-- ## Qué cambia
--
--   · public.ciudad.departamento (text; la columna admite null por las ciudades que ya estaban, ver
--     «Obligatorio»): el departamento al que pertenece la ciudad («Artigas», «Rivera»…). Es un dato de la
--     ciudad, no una entidad aparte. Una restricción lo cuida: si está, no puede quedar en blanco, ni con
--     espacios (o saltos de línea) en los costados, ni pasar de 60 caracteres (así «Salto» y «Salto » no
--     son dos grupos distintos en el filtro del panel).
--   · Un trigger lo exige hacia adelante (CD001, «Cargá el departamento de la ciudad»): una ciudad nueva
--     sin departamento no se carga y a una que ya lo tenía no se le puede borrar. Ver «Obligatorio».
--   · Montevideo: si la base ya la tiene (una sola, viva, del país UY y con su centro adentro del
--     rectángulo de la 0031), se le carga 'Montevideo'. El UPDATE pasa por el trigger de auditoría: sube
--     su `sync_version` y llega a los teléfonos por delta. Las demás ciudades NO se tocan: el
--     departamento de una ciudad real que cargó alguien a mano no se adivina (no hay ninguna lista de
--     ciudades en el repo); se carga con docs/guia-carga-manual.md §2 («Ciudades sin departamento»).
--   · ciudades_de_campania(p_campania_id) -> (campania_ciudad_id, ciudad_id, nombre, departamento,
--     lat_centro, lon_centro, zoom_inicial, cantidad_zonas). Suma `departamento` después de `nombre`.
--   · ciudades_del_catalogo(p_campania_id, p_texto) -> (ciudad_id, nombre, departamento). Suma
--     `departamento` Y también BUSCA por él: con texto, las ciudades cuyo nombre o cuyo departamento lo
--     contienen (sin mayúsculas ni tildes, normalizar_busqueda(); el texto es literal). Escribir «Salto»
--     encuentra Salto y las demás ciudades del departamento de Salto. Orden: primero las cuyo nombre
--     empieza con lo escrito (como hasta hoy), después el resto A-Z por nombre y, a igual nombre, por
--     departamento (las dos «San José» salen una detrás de la otra, cada una con el suyo), a igual
--     departamento por id.
--
-- Las dos funciones cambian de forma (columnas de la respuesta): PostgreSQL no deja `create or replace`
-- con otra lista de columnas, así que se hace `drop function` y `create function`, y se vuelven a
-- otorgar los privilegios de la 0033 (la tabla de ahí: solo `authenticated` ejecuta). Los permisos, los
-- errores (42501, CZ001, CZ011) y el comportamiento de los filtros son los de la 0033.
--
-- ## Obligatorio (HU-ADM-005: «es obligatorio en toda ciudad»)
--
-- Decisión del orquestador (21/10), por el mapa de decisiones (datos de antes de producción: la regla nueva se
-- aplica hacia adelante, sin inventar ni limpiar lo viejo; y el mismo tope en el servidor que en la UI):
-- ni un NOT NULL ni un CHECK ... NOT VALID (este último traba también cualquier UPDATE de una ciudad
-- vieja sin departamento, hasta su baja o la carga del bbox). En su lugar, el trigger
-- `ciudad_departamento_obligatorio` (BEFORE INSERT OR UPDATE OF departamento) rechaza con el SQLSTATE
-- `CD001` y el texto «Cargá el departamento de la ciudad»:
--
--   · un INSERT de una ciudad sin departamento (null);
--   · un UPDATE que le borra el departamento (de no-null a null) a una ciudad que ya lo tenía.
--
-- Lo que NO rechaza: las ciudades viejas que siguen sin departamento se pueden actualizar (nombre,
-- centro, rectángulo, zoom) y dar de baja como siempre; un UPDATE que no nombra `departamento` ni siquiera
-- dispara el trigger, y uno que lo deja en null donde ya era null pasa. Se completan con la consulta de
-- docs/guia-carga-manual.md (§ 2, «Ciudades sin departamento»). Un departamento en blanco, con espacios
-- en los costados o de más de 60 caracteres lo sigue rechazando `ciudad_departamento_check` (23514). La
-- ciudad no viaja desde el teléfono (`sync.entidad.permite_push = false`), así que exigirlo no hace
-- perder nada que suba tarde. La lectura devuelve `departamento` null para una ciudad vieja sin cargar y
-- el panel tiene que cubrirlo. Cuando no quede ninguna ciudad sin cargar, pasar a NOT NULL es opcional
-- (no hace falta un issue aparte).
--
-- ## Los datos
--
-- Se preservan todos: `add column` opcional (instantáneo, sin reescribir la tabla), sin `delete` ni
-- `insert`. El único UPDATE es el de Montevideo, y solo si su departamento estaba vacío.
--
-- ## Para otros repos
--
--   · front-coordinadores-web#40 (vista 24): rótulo «BUSCAR POR NOMBRE O DEPARTAMENTO»; el
--     departamento en cada resultado y en su `aria-label`. Y la vista 31 / reportes: agrupar y filtrar
--     por `ciudades_de_campania().departamento`. Un `null` es una ciudad todavía sin departamento.
--   · front-colportores-mobile y el motor de sync: `ciudad` trae `departamento` en el pull (el pull manda
--     todas las columnas de la entidad, sync.expresion_json); la app lo puede ignorar hasta que lo use.
--   · docs-organizacion: esquema-datos.md ya lo describe; el contrato del sync (la fila de `ciudad`)
--     suma `departamento`.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. ciudad.departamento
-- ----------------------------------------------------------------------------

alter table public.ciudad
  add column departamento text;

alter table public.ciudad
  add constraint ciudad_departamento_check check (
    departamento is null
    or (departamento ~ '^\S(.*\S)?$' and char_length(departamento) <= 60)
  );

comment on column public.ciudad.departamento is
  'Departamento al que pertenece la ciudad («Artigas», «Rivera»…; 0063, backend-supabase#92, decisión de '
  'Cristian del 21/10, «Departamento»). El panel agrupa y filtra departamento -> ciudad y el buscador de '
  '«+ Agregar ciudad» busca también por él. Obligatorio en toda ciudad (HU-ADM-005), pero opcional en la '
  'base solo por las ciudades que ya estaban (null = todavía sin cargar): el trigger ciudad_departamento_obligatorio '
  'rechaza (CD001) una ciudad nueva sin él y que se le borre a una que lo tenía. Sin espacios en los '
  'costados ni en blanco, hasta 60 caracteres. Baja en el pull con la ciudad.';

-- Montevideo, si ya está cargada y es una sola. Mismo criterio que el rectángulo de la 0031 (UY, viva,
-- centro adentro del rectángulo de Montevideo); no se mira el rectángulo cargado.
do $$
declare
  v_ids uuid[];
begin
  select array_agg(c.id)
    into v_ids
    from public.ciudad c
    join public.pais p on p.id = c.pais_id
   where p.iso_code = 'UY'
     and c.nombre = 'Montevideo'
     and c.deleted_at is null
     and c.departamento is null
     and c.lon_centro between -56.433 and -55.948
     and c.lat_centro between -34.945 and -34.701;

  if cardinality(v_ids) = 1 then
    update public.ciudad
       set departamento = 'Montevideo'
     where id = v_ids[1];
  end if;
end
$$;

-- ----------------------------------------------------------------------------
-- 2. ciudades_de_campania(): suma el departamento
-- ----------------------------------------------------------------------------

drop function public.ciudades_de_campania(uuid);

create function public.ciudades_de_campania(p_campania_id uuid)
returns table (campania_ciudad_id uuid, ciudad_id uuid, nombre text, departamento text,
               lat_centro double precision, lon_centro double precision, zoom_inicial smallint,
               cantidad_zonas integer)
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  perform public.exigir_lectura_de_campania(p_campania_id);

  return query
    select cc.id, c.id, c.nombre, c.departamento, c.lat_centro, c.lon_centro, c.zoom_inicial,
           (select count(*)::integer
              from public.zona z
             where z.campania_ciudad_id = cc.id and z.deleted_at is null)
      from public.campania_ciudad cc
      join public.ciudad c on c.id = cc.ciudad_id
     where cc.campania_id = p_campania_id
       and cc.deleted_at is null
     order by c.nombre, cc.id;
end;
$$;

comment on function public.ciudades_de_campania(uuid) is
  'Vista 24 (0033, con departamento desde 0063): las ciudades vivas de p_campania_id con su departamento '
  '(null = sin cargar), centro, zoom y cantidad de zonas vivas. campania_ciudad_id es el id de la pestaña; '
  'ciudad_id, el del catálogo. Errores: 42501 sin permiso; CZ001 inexistente; CZ011 terminada.';

-- ----------------------------------------------------------------------------
-- 3. ciudades_del_catalogo(): suma el departamento y busca por él
-- ----------------------------------------------------------------------------

drop function public.ciudades_del_catalogo(uuid, text);

create function public.ciudades_del_catalogo(p_campania_id uuid, p_texto text default null)
returns table (ciudad_id uuid, nombre text, departamento text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_texto text := public.normalizar_busqueda(p_texto);
begin
  perform public.exigir_lectura_de_campania(p_campania_id);

  -- strpos y no LIKE: el texto es literal, un «%» o un «_» no son comodines. El departamento null (una
  -- ciudad todavía sin cargar) no encuentra nada por departamento; normalizar_busqueda(null) es null.
  return query
    select c.id, c.nombre, c.departamento
      from public.ciudad c
     where c.deleted_at is null
       and not exists (select 1
                         from public.campania_ciudad cc
                        where cc.campania_id = p_campania_id
                          and cc.ciudad_id = c.id
                          and cc.deleted_at is null)
       and (v_texto is null
            or strpos(public.normalizar_busqueda(c.nombre), v_texto) > 0
            or strpos(coalesce(public.normalizar_busqueda(c.departamento), ''), v_texto) > 0)
     order by (v_texto is not null and strpos(public.normalizar_busqueda(c.nombre), v_texto) = 1) desc,
              c.nombre, c.departamento, c.id;
end;
$$;

comment on function public.ciudades_del_catalogo(uuid, text) is
  'Vista 24, «+ Agregar ciudad» (0033, con departamento desde 0063): ciudades vivas del catálogo que no '
  'están en p_campania_id, con su departamento (null = sin cargar); las cuyo nombre o departamento '
  'contienen p_texto (sin mayúsculas ni tildes; sin texto, todas), primero las cuyo nombre empieza con él '
  'y después A-Z por nombre y departamento. Errores: 42501 sin permiso; CZ001 inexistente; CZ011 terminada.';

-- ----------------------------------------------------------------------------
-- 4. El departamento es obligatorio hacia adelante (CD001)
-- ----------------------------------------------------------------------------

create function public.tg_ciudad_departamento_obligatorio()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- INSERT: la ciudad nueva trae departamento. UPDATE OF departamento: no se lo borra a una que lo tenía
  -- (null -> null, la ciudad vieja, pasa).
  if new.departamento is null
     and (tg_op = 'INSERT' or old.departamento is not null) then
    raise exception using
      errcode = 'CD001',
      message = 'Cargá el departamento de la ciudad',
      hint = 'Toda ciudad lleva su departamento (HU-ADM-005); ver docs/guia-carga-manual.md, § 2.';
  end if;
  return new;
end;
$$;

comment on function public.tg_ciudad_departamento_obligatorio() is
  'BEFORE INSERT OR UPDATE OF departamento de ciudad (0063, backend-supabase#92): CD001 si una ciudad nueva '
  'no trae departamento o si se le borra a una que lo tenía. Las ciudades viejas sin departamento se siguen '
  'actualizando y dando de baja (un UPDATE que no nombra la columna no dispara el trigger).';

create trigger ciudad_departamento_obligatorio
  before insert or update of departamento on public.ciudad
  for each row execute function public.tg_ciudad_departamento_obligatorio();

-- Un trigger corre igual sin EXECUTE: ni siquiera authenticated.
revoke all on function public.tg_ciudad_departamento_obligatorio()
  from public, anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 5. Privilegios (como la 0033: solo `authenticated`)
-- ----------------------------------------------------------------------------

-- `authenticated` y `service_role` también en el revoke: en una base creada desde cero los default
-- privileges de la imagen les dan EXECUTE sobre cada función nueva de public (ver 0008).
revoke all on function public.ciudades_de_campania(uuid), public.ciudades_del_catalogo(uuid, text)
  from public, anon, authenticated, service_role;

grant execute on function public.ciudades_de_campania(uuid), public.ciudades_del_catalogo(uuid, text)
  to authenticated;
