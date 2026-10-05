-- ============================================================================
-- 0027 · El precio de venta cuelga de la ciudad de la campaña, no de la zona (backend-supabase#26)
--
-- Decisión de Cristian del 29/09 (D5, comentario 5900014599): «los precios modificados son por
-- ciudad, no por zona»: la FK del precio de venta va a campania_ciudad. Cada coordinador carga los
-- precios de las ciudades de su campaña, y dos campañas en la misma ciudad no se pisan. Con zonas
-- que se dibujan y se redibujan, atar el precio a la zona haría que cambiar un borde cambiara
-- precios. La RLS sigue al coordinador de la campaña, como el resto del mapa (esquema-datos.md,
-- `precio_por_zona`; HU-CAT-005 y HU-CAT-006; vistas 27 del panel y 04 del teléfono).
--
-- Decisión del orquestador del 02/10, por el mapa de decisiones (coherencia: el día se cuenta en
-- Montevideo; precedente backend-supabase#55, comentario 5954669233; detalle en
-- https://github.com/Colportores/backend-supabase/pull/63#issuecomment-5958649947): el
-- `valido_desde` del precio por campania_ciudad usa public.hoy_montevideo() (0024), no el
-- `current_date` de la sesión (UTC). 0024 lo dejó anotado: «el DEFAULT de precio_por_zona.valido_desde
-- (0001) sigue en current_date; esa tabla la reemplaza backend-supabase#26».
--
-- ## Qué cambia
--
--   · precio_por_zona.zona_id se va y entra campania_ciudad_id (NOT NULL, FK a campania_ciudad).
--     Cada precio pasa a la ciudad de la campaña de su zona. La zona ya no es parte del precio.
--   · Un solo precio vigente a la vez por producto o colección en cada campania_ciudad: las dos
--     restricciones de no solapamiento (`precio_por_zona_producto_sin_solape` y
--     `precio_por_zona_coleccion_sin_solape`, btree_gist) se recrean por campania_ciudad. Dos
--     campañas en la misma ciudad tienen cada una su campania_ciudad: no se pisan. Un precio dado
--     de baja (deleted_at) no cuenta.
--   · valido_desde: el default pasa de current_date a public.hoy_montevideo(). Esa función es pura
--     (no lee datos) y 0024 la dejó solo para service_role; el default se evalúa con quien inserta
--     (el coordinador por la API), así que sin el EXECUTE de authenticated un alta sin fecha falla
--     con 42501. Se le da; anon sigue sin ella.
--   · RLS. Escribe (insert y update) el ADMIN o el COORDINADOR de la campaña de esa
--     campania_ciudad (antes, la de la zona). Lee el ADMIN y quien ve esa campania_ciudad
--     (mis_campania_ciudades(), 0013: las campañas que coordina y las que no terminaron en las que
--     está inscripto, con la inscripción viva): antes leía cualquier autenticado. Los precios de
--     una campaña son de esa campaña: otra campaña en la misma ciudad no los ve. Las bajas lógicas
--     se incluyen, porque la app necesita el tombstone para borrar su réplica.
--   · Sync. La fila del pull cambia de forma (campania_ciudad_id en vez de zona_id) y qué filas ve
--     el usuario depende ahora de sus campañas: entra a sync.entidad.sigue_campanias, como
--     campania_ciudad y zona (0013). Inscribir a un colportor o darle una campaña para coordinar
--     vuelve visible un precio que se cargó antes; sin esto, sus filas quedarían debajo del
--     watermark y el delta no las traería nunca. Con la huella de las campañas, esa entidad baja
--     completa cuando cambian. Esta migración además toca todos los precios (el relleno de
--     campania_ciudad_id es un UPDATE), así que todo teléfono los baja otra vez, ya con la forma
--     nueva.
--
-- ## Los precios que ya hay
--
-- Cada precio va a la campania_ciudad de su zona. Antes de cambiar nada se revisa todo, como 0008 y
-- 0017:
--
--   · Dos precios vivos de zonas de la MISMA campania_ciudad, para el mismo producto o colección,
--     con vigencias que se pisan: si valen lo mismo, se unifican; si valen distinto, la migración
--     se ABORTA y lista cada caso (producto o colección, ciudad, campaña, zonas, importes y
--     vigencias). No se elige uno por su cuenta.
--   · Unificar: queda el precio que empieza primero (a igual comienzo, el de menor id), con la
--     vigencia que cubre a todos los que se pisaban (el comienzo del primero y el fin del que
--     termina último; sin fin si alguno no tenía), y los demás quedan dados de baja (deleted_at):
--     no se borra ninguna fila. Dos precios que no se pisan, aunque valgan lo mismo, se dejan como
--     están. Una cadena (A pisa a B, B pisa a C) se unifica entera.
--   · Los precios ya dados de baja no cuentan para el choque y pasan a su campania_ciudad como
--     están.
--   · Datos de ejemplo del seed viejo: «Libro de Ejemplo A» tenía 25.000 en la «Zona Ejemplo 1» y
--     27.000 en la «Zona Ejemplo 2», dos zonas de la misma ciudad de la misma campaña. Una base
--     sembrada así ABORTA, a propósito: es el caso que describe el issue. seed.sql ya no lo carga
--     (precio distinto, ciudad distinta).
--   · Se pierde de cada precio la zona de la que venía: el precio ya no es de una zona. Lo demás
--     (importe, producto o colección, vigencia, autor, fechas) queda igual.
--
-- ## Lo que NO cambia
--
--   · El nombre de la tabla (precio_por_zona), de la entidad de sync, de las restricciones y del
--     canal de realtime. Renombrarla a precio_por_ciudad es una propuesta del issue que
--     esquema-datos.md deja «sin decidir»; es una decisión de modelo que no tomo acá. Si se
--     decide, es una migración chica (`alter table … rename`, y renombrar índice, restricciones y
--     políticas, y sync.entidad.nombre) más el nombre en los contratos y en las apps. Pendiente de
--     Cristian anotado en el PR.
--   · venta_item.precio_unitario: es la foto del precio al vender. Un precio nuevo vale para las
--     ventas que se registren después de guardarlo; las anteriores conservan el suyo.
--
-- ## Para otros repos
--
--   · front-coordinadores-web (HU-CAT-005, vista 27, front-coordinadores-web#21): los precios se
--     cargan por campania_ciudad (pestañas por ciudad: «Se aplican a las ventas nuevas de
--     Montevideo»), no por zona. Insert y update directos con campania_ciudad_id; `valido_desde`
--     puede ir vacío (hoy en Montevideo). Solapar un precio vigente del mismo producto o colección
--     en la misma ciudad falla con 23P01 (`precio_por_zona_producto_sin_solape` o
--     `precio_por_zona_coleccion_sin_solape`): hay que cerrar el vigente (valido_hasta) antes. El
--     coordinador solo ve y edita los precios de su campaña; no ve los de otra campaña aunque sea
--     la misma ciudad.
--   · front-colportores-mobile y motor de sync (HU-CAT-006, front-colportores-mobile#157):
--     `precio_por_zona` baja sin `zona_id` y con `campania_ciudad_id`. El colportor baja los
--     precios de todas las ciudades de las campañas en las que está inscripto y que no
--     terminaron (la app muestra los de la ciudad que le toca, HU-CAT-006, S55). El precio de una
--     venta es el de la fila vigente de la campania_ciudad (campaña, ciudad de la casa) que no
--     está dada de baja. Avisar a @BrunoFCapri: cambia la forma de la fila del pull y la entidad
--     queda con sigue_campanias.
--   · docs-organizacion: contrato de sync (§2, fila de precio_por_zona: forma y sigue_campanias),
--     esquema-datos.md (FK a campania_ciudad, nombre de la tabla sin decidir) y HU-CAT-005 y 006.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Qué precios no se pueden migrar: se revisa TODO antes de cambiar nada
-- ----------------------------------------------------------------------------

do $$
declare
  v_casos text;
begin
  select string_agg(x.linea, E'\n' order by x.linea)
    into v_casos
    from (
      select format(
               '  · %s, en %s (campaña «%s»): $ %s en la zona «%s»%s (precio %s, %s) y $ %s en la zona «%s»%s (precio %s, %s) valen a la vez.',
               coalesce(pr.nombre, co.nombre), ci.nombre, ca.nombre,
               (a.precio_venta / 100)::text || ',' || lpad((a.precio_venta % 100)::text, 2, '0'),
               za.nombre, case when za.deleted_at is not null then ' (dada de baja)' else '' end,
               a.id,
               'desde ' || to_char(a.valido_desde, 'DD/MM/YYYY') ||
                 coalesce(' hasta ' || to_char(a.valido_hasta, 'DD/MM/YYYY'), ' sin fin'),
               (b.precio_venta / 100)::text || ',' || lpad((b.precio_venta % 100)::text, 2, '0'),
               zb.nombre, case when zb.deleted_at is not null then ' (dada de baja)' else '' end,
               b.id,
               'desde ' || to_char(b.valido_desde, 'DD/MM/YYYY') ||
                 coalesce(' hasta ' || to_char(b.valido_hasta, 'DD/MM/YYYY'), ' sin fin')
             ) as linea
        from public.precio_por_zona a
        join public.zona za on za.id = a.zona_id
        join public.precio_por_zona b
          on b.id > a.id
         and (b.producto_id = a.producto_id or b.coleccion_id = a.coleccion_id)
         and b.precio_venta <> a.precio_venta
         and daterange(b.valido_desde, b.valido_hasta, '[]') && daterange(a.valido_desde, a.valido_hasta, '[]')
        join public.zona zb on zb.id = b.zona_id and zb.campania_ciudad_id = za.campania_ciudad_id
        join public.campania_ciudad cc on cc.id = za.campania_ciudad_id
        join public.ciudad ci on ci.id = cc.ciudad_id
        join public.campania ca on ca.id = cc.campania_id
        left join public.producto pr on pr.id = a.producto_id
        left join public.coleccion co on co.id = a.coleccion_id
       where a.deleted_at is null and b.deleted_at is null
    ) x;

  if v_casos is not null then
    raise exception using
      message = 'La migración 0027 (precio de venta por ciudad) no se aplicó: hay productos o '
                'colecciones con importes distintos al mismo tiempo en zonas de la misma ciudad de '
                'la campaña, y no se elige uno por su cuenta. No se cambió nada.',
      detail  = v_casos,
      hint    = 'En cada caso dejá un solo importe vigente por ciudad de la campaña: cerrá uno con '
                'valido_hasta o dale de baja (deleted_at) a uno de los dos, y volvé a aplicar la '
                'migración.';
  end if;
end
$$;

-- ----------------------------------------------------------------------------
-- 2. campania_ciudad_id: se agrega, se llena desde la zona y los precios que se pisan con el mismo
--    importe se unifican (las restricciones por zona se van antes: son las que podrían frenar el
--    estirar una vigencia)
-- ----------------------------------------------------------------------------

alter table public.precio_por_zona
  drop constraint precio_por_zona_producto_sin_solape,
  drop constraint precio_por_zona_coleccion_sin_solape;

alter table public.precio_por_zona
  add column campania_ciudad_id uuid references public.campania_ciudad(id);

-- Cada precio, a la ciudad de la campaña de su zona (0008: zona.campania_ciudad_id es NOT NULL).
-- Es un UPDATE de todas las filas: sube su sync_version y su xmin_w, y todo teléfono las baja otra
-- vez con la forma nueva.
update public.precio_por_zona p
   set campania_ciudad_id = z.campania_ciudad_id
  from public.zona z
 where z.id = p.zona_id;

do $$
declare
  r           record;
  v_id        uuid;
  v_cc        uuid;
  v_producto  uuid;
  v_coleccion uuid;
  v_hasta     date;
  v_unificados integer := 0;
begin
  -- Por ciudad de campaña y por producto o colección, de la vigencia más vieja a la más nueva. El
  -- paso 1 garantiza que dos precios vivos que se pisan valen lo mismo. Un precio que empieza
  -- dentro de lo que cubre el anterior (con su fin ya estirado) se suma a él.
  for r in
    select p.id, p.campania_ciudad_id, p.producto_id, p.coleccion_id, p.valido_desde, p.valido_hasta
      from public.precio_por_zona p
     where p.deleted_at is null
     order by p.campania_ciudad_id, p.producto_id nulls last, p.coleccion_id nulls last,
              p.valido_desde, p.id
  loop
    if v_id is not null
       and r.campania_ciudad_id = v_cc
       and r.producto_id is not distinct from v_producto
       and r.coleccion_id is not distinct from v_coleccion
       and r.valido_desde <= coalesce(v_hasta, 'infinity'::date) then
      if v_hasta is not null and (r.valido_hasta is null or r.valido_hasta > v_hasta) then
        v_hasta := r.valido_hasta;
        update public.precio_por_zona set valido_hasta = v_hasta where id = v_id;
      end if;
      update public.precio_por_zona set deleted_at = now() where id = r.id;
      v_unificados := v_unificados + 1;
    else
      v_id := r.id;
      v_cc := r.campania_ciudad_id;
      v_producto := r.producto_id;
      v_coleccion := r.coleccion_id;
      v_hasta := r.valido_hasta;
    end if;
  end loop;

  if v_unificados > 0 then
    raise notice '0027: % precio(s) con el mismo importe en zonas de la misma ciudad se unificaron (los repetidos quedaron dados de baja, no borrados).', v_unificados;
  end if;
end
$$;

alter table public.precio_por_zona
  alter column campania_ciudad_id set not null;

-- ----------------------------------------------------------------------------
-- 3. Fuera zona_id (y con él su índice); entran el índice y las restricciones por campania_ciudad
-- ----------------------------------------------------------------------------

-- Las políticas de 0001, 0003 y 0008 miran zona_id: se recrean abajo.
drop policy precio_por_zona_select_autenticado on public.precio_por_zona;
drop policy precio_por_zona_insert_staff on public.precio_por_zona;
drop policy precio_por_zona_update_staff on public.precio_por_zona;

alter table public.precio_por_zona drop column zona_id;

create index precio_por_zona_campania_ciudad_idx on public.precio_por_zona (campania_ciudad_id);

-- Sin dos precios vigentes a la vez para lo mismo en la misma ciudad de la misma campaña: «el precio
-- actual» tiene que ser una sola fila. Una por producto y otra por colección, porque el check de la
-- tabla garantiza que solo una de las dos columnas está cargada.
alter table public.precio_por_zona
  add constraint precio_por_zona_producto_sin_solape
  exclude using gist (
    campania_ciudad_id with =,
    producto_id with =,
    daterange(valido_desde, valido_hasta, '[]') with &&
  ) where (deleted_at is null and producto_id is not null);

alter table public.precio_por_zona
  add constraint precio_por_zona_coleccion_sin_solape
  exclude using gist (
    campania_ciudad_id with =,
    coleccion_id with =,
    daterange(valido_desde, valido_hasta, '[]') with &&
  ) where (deleted_at is null and coleccion_id is not null);

comment on table public.precio_por_zona is
  'Precio de venta de un producto o una colección en una ciudad de una campaña (campania_ciudad_id), '
  'no por zona (0027, decisión de Cristian del 29/09). El nombre viene de cuando era por zona; '
  'renombrarlo a precio_por_ciudad está sin decidir. Un solo precio vigente a la vez por producto o '
  'colección en cada campania_ciudad. Un precio nuevo vale para las ventas siguientes: venta_item '
  'guarda el suyo.';

comment on column public.precio_por_zona.campania_ciudad_id is
  'La ciudad de la campaña a la que se aplica el precio. Dos campañas en la misma ciudad tienen '
  'cada una el suyo.';

-- ----------------------------------------------------------------------------
-- 4. valido_desde: el día de Montevideo
-- ----------------------------------------------------------------------------

alter table public.precio_por_zona
  alter column valido_desde set default public.hoy_montevideo();

-- El default lo evalúa quien inserta (el coordinador, por la API): necesita ejecutarla. Es pura
-- (no lee datos ni toca nada): que authenticated la ejecute no abre nada. anon sigue sin ella.
grant execute on function public.hoy_montevideo(timestamptz) to authenticated;

comment on function public.hoy_montevideo(timestamptz) is
  'El día de p_ahora (por defecto, ahora) en America/Montevideo, sin depender de la zona horaria '
  'de la sesión. Única definición de «hoy» para la vigencia de una campaña (0024) y para el '
  'valido_desde por defecto de precio_por_zona (0027, que la evalúa con quien inserta: por eso la '
  'ejecuta authenticated). Pura.';

-- ----------------------------------------------------------------------------
-- 5. RLS
-- ----------------------------------------------------------------------------

-- Lee el ADMIN y quien ve la campania_ciudad (las campañas que coordina y las que no terminaron en
-- las que está inscripto). Incluye las bajas lógicas: la app necesita el tombstone.
create policy precio_por_zona_select on public.precio_por_zona
  for select to authenticated
  using ((select public.tiene_rol('ADMIN'))
         or campania_ciudad_id in (select public.mis_campania_ciudades()));

-- Escribe el ADMIN, o el COORDINADOR de la campaña de esa campania_ciudad (R-CT02, HU-CAT-005).
create policy precio_por_zona_insert_staff on public.precio_por_zona
  for insert to authenticated
  with check (
    (select public.tiene_rol('ADMIN'))
    or ((select public.tiene_rol('COORDINADOR')) and exists (
          select 1 from public.campania_ciudad cc
            join public.campania c on c.id = cc.campania_id
           where cc.id = precio_por_zona.campania_ciudad_id and c.coordinador_id = (select auth.uid())))
  );

create policy precio_por_zona_update_staff on public.precio_por_zona
  for update to authenticated
  using (
    (select public.tiene_rol('ADMIN'))
    or ((select public.tiene_rol('COORDINADOR')) and exists (
          select 1 from public.campania_ciudad cc
            join public.campania c on c.id = cc.campania_id
           where cc.id = precio_por_zona.campania_ciudad_id and c.coordinador_id = (select auth.uid())))
  )
  with check (
    (select public.tiene_rol('ADMIN'))
    or ((select public.tiene_rol('COORDINADOR')) and exists (
          select 1 from public.campania_ciudad cc
            join public.campania c on c.id = cc.campania_id
           where cc.id = precio_por_zona.campania_ciudad_id and c.coordinador_id = (select auth.uid())))
  );

-- ----------------------------------------------------------------------------
-- 6. Sync: qué filas ve el usuario depende de sus campañas
-- ----------------------------------------------------------------------------

update sync.entidad set sigue_campanias = true where nombre = 'precio_por_zona';
