-- ============================================================================
-- 0017 · Dirección única a menos de 100 m (D1) y normalización con espacios y tildes
--        (backend-supabase#34)
--
-- Decisión D1 de Cristian (29/09, backend-supabase#24, comentario 5900053347): «Dos ubicaciones
-- chocan cuando tienen la misma dirección normalizada (ciudad, calle y número) y están a menos de
-- 100 m una de otra. Con la misma dirección a 100 m o más, se aceptan las dos. […] El push que
-- choca devuelve un conflicto (el 23505 u otro código acordado con el motor, #178). La fila queda
-- en el celular y la app lo resuelve con la vista 10, así que no se pierde nada.»
-- Decisión 3 de front-colportores-mobile#207 (comentario 5900419787): «además de trim y
-- minúsculas, se juntan los espacios internos y los raros (tabs, espacios duros) y se sacan las
-- tildes: unaccent en direccion_normalizada() del servidor y lo mismo en Dart. Hay que rehacer el
-- índice de 0010 […] y aplica a la regla de dirección única de D1.»
-- Esquema: docs/esquema-datos.md, `ubicacion` (RF-UB08). Contrato de sync §2.2.
--
-- ## 1. direccion_normalizada(), con espacios y tildes
--
-- En este orden: unaccent (el diccionario `unaccent` de Postgres), cada carácter de espacio
-- Unicode (tabla abajo) pasa a un espacio común y los seguidos se juntan en uno, trim, minúsculas;
-- vacío = null. «  Av.  Itália » y «av. italia» dan lo mismo. Sigue IMMUTABLE: la usan índices.
-- El índice de dirección de 0010 (ubicacion_direccion_idx) se rehace, porque sus entradas se
-- calcularon con la versión vieja. posibles_duplicados_de_ubicacion() (el aviso de 0010) la usa, así
-- que el aviso también pasa a ignorar tildes y espacios.
--
-- ## 2. La regla: trigger con distancia, no índice único
--
-- «A menos de 100 m» no es una igualdad, así que no hay índice único que la cubra, y un EXCLUDE
-- con && sobre círculos compara cajas, no distancias. Va un trigger AFTER INSERT/UPDATE en
-- ubicacion (por cualquier camino: push, RPC, servidor):
--   · participan las filas vivas (deleted_at null) con calle Y número normalizados no nulos; las
--     dadas de baja y las que no tienen calle o número quedan afuera, de los dos lados;
--   · chocan dos filas de la misma ciudad (ciudad_id), con la misma calle y el mismo número
--     normalizados, a menos de 100 m (ST_Distance sobre geography, elipsoide: < 100). A 100 m
--     justos se aceptan;
--   · se revisa al insertar, y al cambiar calle, número, posición o ciudad, o al reactivar
--     (deleted_at vuelve a null). Cambiar otra cosa no revisa nada;
--   · SECURITY DEFINER: tiene que ver TODAS las ubicaciones, también las que la RLS no le muestra a
--     quien escribe (la casa que registró otro colportor, en otra zona). No devuelve nada de la
--     otra fila: ni su id ni su posición;
--   · carrera: dos altas de la misma dirección al mismo tiempo no se ven entre sí (ninguna hizo
--     commit). El trigger toma un lock advisory por (ciudad, calle, número) normalizados hasta el
--     final de la transacción y recién ahí mira: la segunda espera a que la primera termine y la
--     ve. Supone READ COMMITTED (el default de PostgREST y de sync.push): en REPEATABLE READ la
--     segunda no vería a la primera. Un lote que registra dos direcciones y otro que registra las
--     mismas en orden inverso pueden trabarse; Postgres corta a uno (sale 500 y el motor
--     reintenta), como el lock por ciudad de 0010.
-- El error: 23505 (unique_violation) con constraint = 'ubicacion_direccion_unica', y un mensaje que
-- dice qué hacer (abrir la existente, o corregir la dirección o la posición).
--
-- ## 3. El push: conflicto, no invalid (PROPUESTA, pendiente con el motor)
--
-- Hasta acá sync.aplicar_job() devolvía todo 23505 como `invalid`. Ahora, SOLO el de esta regla
-- (por el nombre de la restricción) vuelve como conflicto; el resto de la clase 23 sigue invalid:
--
--   {"client_op_id": …, "outcome": "conflict", "code": "23505",
--    "constraint": "ubicacion_direccion_unica", "message": "Ya hay otra ubicación en …"}
--
-- Sin server_row ni sync_version, a propósito: el conflicto de siempre (LWW por sync_version)
-- trae la fila del servidor para que el motor la aplique, y acá eso pisaría la fila del teléfono.
-- La fila queda en el celular, el servidor no escribe nada (ni la fila ni el cache de
-- client_op_id: un reintento se vuelve a revisar), y la app lo resuelve con la vista 10. Las
-- claves y el estado del job mientras tanto se acuerdan con el motor
-- (front-colportores-mobile#178, contrato §2.2); este formato es la propuesta del backend.
--
-- ## 4. Duplicados que ya están en la base
--
-- Antes de crear el trigger se revisan las ubicaciones vivas con la regla nueva (ya con tildes y
-- espacios). En cada dirección, en orden de alta (created_at, id), una ubicación que cae a menos
-- de 100 m de otra anterior que se queda es un duplicado (B) de la primera de esas (A): es
-- exactamente lo que la regla habría rechazado si hubiera existido. Una tercera a más de 100 m
-- de A pero cerca de B se queda, porque B sale. Lectura del issue («antes limpia los duplicados
-- vivos […] La limpieza preserva los datos: si una fila no se puede migrar, la migración se aborta
-- con un mensaje que diga cuál y por qué»), anotada en backend-supabase#34:
--   · B sin nada colgado (ninguna persona en sus espacios, ni viva ni de baja; sin estado en el
--     mapa; sin espacios con departamento, piso o descripción, ni más de uno; y que ninguna
--     cobranza ni agenda la use como dirección alternativa) se da de baja (deleted_at): no se
--     borra nada, la fila queda y se puede reactivar. El teléfono la recibe como baja en el
--     próximo pull, como cualquier baja.
--   · B con algo colgado NO se toca: pasar sus personas a A es «Marcar como duplicado» de la vista
--     10 (HU-UBI-006, decisión 2 de front-colportores-mobile#207), y lo hace la app, porque las
--     personas viven en el teléfono y espacio_persona no baja por el pull. La migración aborta sin
--     cambiar nada y lista cada B con su A y qué hacer.
--
-- ## Para otros repos
--
--   · front-colportores-mobile (#207, #193, #202, #208, #233): la normalización en Dart tiene que
--     dar lo mismo. Espacios: [\u0009-\u000D \u0085   -
--       　﻿]+ → ' '. Tildes: las reglas de unaccent de Postgres (unaccent.rules),
--     que además de las tildes pasan ñ → n, ü → u, ç → c, æ → ae, ß → ss y otras ligaduras.
--     Chocar a menos de 100 m es ST_Distance sobre el elipsoide WGS84 (< 100, estricto).
--   · Motor de sync (#178, Bruno): el outcome `conflict` con code 23505 y constraint
--     'ubicacion_direccion_unica' no trae server_row: no se aplica LWW; la fila queda local y el job
--     espera a que la app lo resuelva (vista 10). Forma pendiente de acuerdo.
--   · Panel y BFF: una escritura directa que choca recibe el 23505 con el mensaje y el hint.
--
-- ## Orden de despliegue
--
-- Va arriba de la pila #36…#48 (0011–0016), con número 0017 y timestamp posterior a 0016: entra
-- después, porque deploy.yml corre `supabase db push` sin --include-all. La migración no usa nada
-- de 0011–0016 (no toca sync.pull, las zonas ni la RLS); lo que la ata a la pila son los fixtures
-- de 0002_rls_test y 0013_ubicacion_sin_zona_test, que la pila ya había cambiado.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. unaccent
-- ----------------------------------------------------------------------------

create extension if not exists unaccent with schema extensions;

do $$
declare
  v_esquema text;
begin
  select n.nspname into v_esquema
    from pg_extension e join pg_namespace n on n.oid = e.extnamespace
   where e.extname = 'unaccent';
  if v_esquema is distinct from 'extensions' then
    raise exception using
      message = format('La migración 0017 no se aplicó: la extensión unaccent está en el esquema %s '
                       'y direccion_normalizada() la busca en extensions. No se cambió nada.', v_esquema),
      hint    = 'Movela con «alter extension unaccent set schema extensions» y volvé a aplicar la migración.';
  end if;
end
$$;

-- ----------------------------------------------------------------------------
-- 2. direccion_normalizada(): tildes y espacios; el índice de 0010 se rehace
-- ----------------------------------------------------------------------------

-- unaccent con el diccionario explícito (dos argumentos): con search_path vacío la versión de un
-- argumento no encuentra el diccionario. La clase de espacios es la de «Para otros repos».
create or replace function public.direccion_normalizada(p_texto text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select nullif(lower(btrim(regexp_replace(
           extensions.unaccent('extensions.unaccent'::regdictionary, p_texto),
           '[\u0009-\u000d \u0085   -     　﻿]+',
           ' ', 'g'))), '');
$$;

comment on function public.direccion_normalizada(text) is
  'Calle o número normalizados para comparar direcciones (D1, front-colportores-mobile#207): '
  'unaccent, espacios Unicode juntados en uno, trim y minúsculas; vacío = null. La app usa la misma '
  'en Dart.';

drop index public.ubicacion_direccion_idx;
create index ubicacion_direccion_idx on public.ubicacion
  (ciudad_id, public.direccion_normalizada(calle), public.direccion_normalizada(numero))
  where deleted_at is null;

comment on index public.ubicacion_direccion_idx is
  'No es único: D1 mira la distancia (a menos de 100 m), así que la hace cumplir el trigger '
  'ubicacion_direccion_unica_* (0017). Este índice le acelera la búsqueda y al aviso de duplicados.';

-- ----------------------------------------------------------------------------
-- 3. Duplicados vivos que ya están en la base: se revisa todo antes de cambiar nada
-- ----------------------------------------------------------------------------

do $$
declare
  v_f          record;
  v_a          record;
  v_problemas  text;
  v_bajas      text;
  v_cant_bajas integer;
begin
  -- Las que chocan con alguna: las demás no cambian nada.
  create temp table d1_candidata on commit drop as
  select u.id, u.ciudad_id, u.calle, u.numero, u.created_at,
         public.direccion_normalizada(u.calle)  as calle_n,
         public.direccion_normalizada(u.numero) as numero_n,
         public.ubicacion_geografia(u.lat, u.lon) as punto
    from public.ubicacion u
   where u.deleted_at is null
     and public.direccion_normalizada(u.calle) is not null
     and public.direccion_normalizada(u.numero) is not null
     and exists (
       select 1 from public.ubicacion o
        where o.id <> u.id
          and o.deleted_at is null
          and o.ciudad_id = u.ciudad_id
          and public.direccion_normalizada(o.calle) = public.direccion_normalizada(u.calle)
          and public.direccion_normalizada(o.numero) = public.direccion_normalizada(u.numero)
          and extensions.st_dwithin(public.ubicacion_geografia(o.lat, o.lon),
                                    public.ubicacion_geografia(u.lat, u.lon), 100.0::double precision)
          and extensions.st_distance(public.ubicacion_geografia(o.lat, o.lon),
                                     public.ubicacion_geografia(u.lat, u.lon)) < 100.0);

  create temp table d1_queda (like d1_candidata) on commit drop;
  create temp table d1_duplicada (b_id uuid primary key, a_id uuid not null,
                                  distancia double precision not null) on commit drop;

  -- En orden de alta: la que cae a menos de 100 m de una que ya se queda es duplicado de la
  -- primera de esas; si no, se queda.
  for v_f in select * from d1_candidata order by ciudad_id, calle_n, numero_n, created_at, id loop
    select q.id, extensions.st_distance(q.punto, v_f.punto) as distancia
      into v_a
      from d1_queda q
     where q.ciudad_id = v_f.ciudad_id
       and q.calle_n = v_f.calle_n
       and q.numero_n = v_f.numero_n
       and extensions.st_distance(q.punto, v_f.punto) < 100.0
     order by q.created_at, q.id
     limit 1;
    if found then
      insert into d1_duplicada values (v_f.id, v_a.id, v_a.distancia);
    else
      insert into d1_queda (id, ciudad_id, calle, numero, created_at, calle_n, numero_n, punto)
      values (v_f.id, v_f.ciudad_id, v_f.calle, v_f.numero, v_f.created_at, v_f.calle_n, v_f.numero_n, v_f.punto);
    end if;
  end loop;

  -- Qué cuelga de cada B.
  create temp table d1_revision on commit drop as
  select d.b_id, d.a_id, d.distancia,
         exists (select 1 from public.espacio_persona ep join public.espacio e on e.id = ep.espacio_id
                  where e.ubicacion_id = d.b_id) as con_personas,
         exists (select 1 from public.house_status h
                  where h.ubicacion_id = d.b_id and h.deleted_at is null) as con_estado,
         (select count(*) from public.espacio e
           where e.ubicacion_id = d.b_id and e.deleted_at is null) > 1
         or exists (select 1 from public.espacio e
                     where e.ubicacion_id = d.b_id and e.deleted_at is null
                       and (nullif(btrim(e.numero_depto), '') is not null
                            or nullif(btrim(e.piso), '') is not null
                            or nullif(btrim(e.descripcion), '') is not null)) as con_espacios,
         exists (select 1 from public.espacio_persona ep where ep.ubicacion_cobranza_alt_id = d.b_id)
         or exists (select 1 from public.agenda ag where ag.ubicacion_alt_id = d.b_id) as referenciada
    from d1_duplicada d;

  select string_agg(
           format('  · %s %s (%s, registrada por %s el %s) está a %s m de %s %s (%s), con la misma '
                  'dirección, y tiene %s. Si es la misma casa, marcala como duplicado de la otra desde '
                  'la app (vista 10, «Posibles duplicados»: pasa sus personas a la otra y la da de '
                  'baja); si es otra casa, corregí su dirección o su posición. Después volvé a '
                  'aplicar la migración.',
                  b.calle, b.numero, b.id, coalesce(b.created_by::text, 'nadie'),
                  to_char(b.created_at, 'DD/MM/YYYY'), round(r.distancia::numeric, 1),
                  a.calle, a.numero, a.id,
                  array_to_string(array_remove(array[
                    case when r.con_personas then 'personas en sus espacios' end,
                    case when r.con_estado then 'estado en el mapa' end,
                    case when r.con_espacios then 'departamentos o espacios cargados' end,
                    case when r.referenciada then 'cobranzas o agendas que la usan como dirección alternativa' end
                  ], null), ', ')),
           E'\n' order by b.ciudad_id, b.id)
    into v_problemas
    from d1_revision r
    join public.ubicacion b on b.id = r.b_id
    join public.ubicacion a on a.id = r.a_id
   where r.con_personas or r.con_estado or r.con_espacios or r.referenciada;

  select count(*) into v_cant_bajas
    from d1_revision r
   where not (r.con_personas or r.con_estado or r.con_espacios or r.referenciada);

  if v_problemas is not null then
    raise exception using
      message = 'La migración 0017 (dirección única a menos de 100 m) no se aplicó: hay ubicaciones '
                'vivas con la misma dirección a menos de 100 m que tienen datos colgados. No se '
                'cambió nada.',
      detail  = v_problemas || case when v_cant_bajas > 0
                                    then format(E'\n  Además, %s duplicada(s) sin nada colgado se van a dar '
                                                'de baja solas al volver a aplicar.', v_cant_bajas)
                                    else '' end,
      hint    = 'Resolvé cada ubicación de la lista y volvé a aplicar la migración.';
  end if;

  -- Las que no tienen nada: de baja. No se borra nada; se pueden reactivar.
  select string_agg(format('  · %s %s (%s): duplicada de %s, a %s m', b.calle, b.numero, b.id,
                           r.a_id, round(r.distancia::numeric, 1)), E'\n' order by b.id)
    into v_bajas
    from d1_revision r join public.ubicacion b on b.id = r.b_id;

  update public.ubicacion u
     set deleted_at = now()
    from d1_revision r
   where u.id = r.b_id;

  if v_bajas is not null then
    raise notice E'0017: % ubicación(es) duplicada(s) sin nada colgado quedaron de baja:\n%',
      v_cant_bajas, v_bajas;
  end if;
end
$$;

-- ----------------------------------------------------------------------------
-- 4. La regla: trigger en ubicacion
-- ----------------------------------------------------------------------------

create function public.tg_ubicacion_direccion_unica()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_calle  text := public.direccion_normalizada(new.calle);
  v_numero text := public.direccion_normalizada(new.numero);
  v_punto  extensions.geography;
begin
  if new.deleted_at is not null or v_calle is null or v_numero is null then
    return null;
  end if;

  -- Hasta el commit: la otra alta de la misma dirección espera acá y después ve esta fila.
  perform pg_advisory_xact_lock(hashtextextended(
    'direccion_unica:' || new.ciudad_id::text || ':' || v_calle || ':' || v_numero, 0));

  v_punto := public.ubicacion_geografia(new.lat, new.lon);

  if exists (
    select 1 from public.ubicacion u
     where u.ciudad_id = new.ciudad_id
       and public.direccion_normalizada(u.calle) = v_calle
       and public.direccion_normalizada(u.numero) = v_numero
       and u.deleted_at is null
       and u.id <> new.id
       and extensions.st_dwithin(public.ubicacion_geografia(u.lat, u.lon), v_punto, 100.0::double precision)
       and extensions.st_distance(public.ubicacion_geografia(u.lat, u.lon), v_punto) < 100.0
  ) then
    raise exception using
      errcode    = 'unique_violation',
      constraint = 'ubicacion_direccion_unica',
      schema     = 'public',
      table      = 'ubicacion',
      message    = format('Ya hay otra ubicación en «%s %s» a menos de 100 m.',
                          btrim(new.calle), btrim(new.numero)),
      hint       = 'Si es la misma casa, abrí la existente; si es otra, corregí la dirección o la '
                   'posición: con la misma dirección tienen que estar a 100 m o más.';
  end if;

  return null;
end;
$$;

comment on function public.tg_ubicacion_direccion_unica() is
  'D1: dos ubicaciones vivas de la misma ciudad con la misma calle y número normalizados no pueden '
  'estar a menos de 100 m. 23505 con constraint ubicacion_direccion_unica. SECURITY DEFINER: mira '
  'todas las filas, no solo las que la RLS le muestra a quien escribe (0017).';

create trigger ubicacion_direccion_unica_insert
  after insert on public.ubicacion
  for each row
  when (new.deleted_at is null and new.calle is not null and new.numero is not null)
  execute function public.tg_ubicacion_direccion_unica();

create trigger ubicacion_direccion_unica_update
  after update on public.ubicacion
  for each row
  when (new.deleted_at is null and new.calle is not null and new.numero is not null
        and (old.calle is distinct from new.calle
             or old.numero is distinct from new.numero
             or old.lat is distinct from new.lat
             or old.lon is distinct from new.lon
             or old.ciudad_id is distinct from new.ciudad_id
             or old.deleted_at is not null))
  execute function public.tg_ubicacion_direccion_unica();

-- ----------------------------------------------------------------------------
-- 5. El push: el choque de D1 vuelve como conflicto (propuesta, ver arriba)
-- ----------------------------------------------------------------------------

-- Igual que en 0002, salvo el handler: el 23505 de ubicacion_direccion_unica es `conflict`.
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
end;
$$;

-- ----------------------------------------------------------------------------
-- 6. Privilegios
-- ----------------------------------------------------------------------------

-- `authenticated` también: en una base creada desde cero los default privileges de la imagen le
-- dan EXECUTE sobre cada función nueva de public (ver 0008). El trigger corre igual sin EXECUTE.
revoke all on function public.tg_ubicacion_direccion_unica() from public, anon, authenticated;
