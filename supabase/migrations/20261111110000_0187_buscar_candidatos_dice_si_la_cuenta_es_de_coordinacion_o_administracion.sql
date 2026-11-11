-- ============================================================================
-- 0187 · buscar_candidatos() dice si la cuenta es de coordinación o de administración
--        (HU-CAM-004, vista 23 «Añadir colportor a la campaña»; decisión de Cristian del 11/11: a un coordinador o a un
--        administrador se lo puede seguir añadiendo como colportor, pero el panel tiene que advertirlo)
--
-- ## El caso
--
-- Luis, coordinador de «Verano», abre Equipo → «+ Añadir colportor» en el panel para sumar a un colportor nuevo. En la lista
-- aparece también la cuenta de Marta, que es coordinadora: la regla «Coordinador o admin como colportor» de HU-CAM-004
-- (Cristian, 02/10, backend-supabase#41) deja inscribirla, y sigue igual. Pero nada en la fila decía que esa cuenta no era la
-- de un colportor, y el 11/11 se añadió una cuenta de coordinador por error. El panel necesita el dato para poner una
-- etiqueta junto al nombre y pedir una confirmación antes de añadirla.
--
-- ## Qué cambia
--
--   buscar_candidatos(p_campania_id, p_texto, p_despues_de)
--     -> (usuario_id, nombre, apellido, email, estado, campania_actual, creada_en, motivo_bloqueo, rol_cuenta)
--
-- Una columna más, **al final**; las ocho de antes siguen con el mismo nombre, tipo y orden:
--
--   rol_cuenta text   'ADMIN' si la cuenta tiene hoy el rol de administrador; si no, 'COORDINADOR' si tiene hoy el de
--                     coordinador (de cualquier campaña); si no, null (la cuenta de un colportor o sin rol).
--
-- «Tiene hoy el rol» es el criterio de `cuenta_tiene_rol()` (0177), el mismo de `tiene_rol()` y de
-- `acompaniantes_del_panel()` (0183): rol vigente de una cuenta que no está dada de baja ni suspendida. Una cuenta con los dos
-- roles sale 'ADMIN'. Una cuenta de coordinación suspendida sale con null: ya viene bloqueada por la suspensión y no se puede
-- añadir.
--
-- **Lo demás no cambia**: quién aparece, el orden, las páginas, `estado`, `campania_actual` y `motivo_bloqueo` son los de la
-- 0102, y `inscribir_colportor()` no se toca. No se filtra por rol ni en la búsqueda ni en la inscripción (decisión del 02/10,
-- que se mantiene): el dato solo sirve para avisar.
--
-- ## Por qué DROP y CREATE
--
-- Cambiar las columnas que devuelve una función no se puede con `create or replace` (42P13): se borra y se vuelve a crear con
-- la misma firma `(uuid, text, uuid)`, el mismo comentario de la 0102 más la columna, y los mismos privilegios de la 0015
-- (EXECUTE para `authenticated` y `service_role`; ni `anon` ni PUBLIC). Nada en la base depende de ella (ninguna vista, política
-- ni otra función la llama). El cuerpo es la copia entera del de la 0102 con la columna nueva en el `select` final.
--
-- ## Los datos
--
-- Solo una función; no toca filas. Lo prueba supabase/tests/0187_… . Forward-only.
--
-- ## Para otros repos
--
--   · front-coordinadores-web (vista 23): PostgREST devuelve las columnas por nombre, así que el panel viejo sigue andando
--     con la función nueva (ignora `rol_cuenta`) y el panel nuevo con la función vieja (sin la columna no pone la etiqueta).
--   · docs-organizacion: la columna en la fila de la RPC del contrato y el aviso en HU-CAM-004 (entrada «Sin publicar»).
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

drop function public.buscar_candidatos(uuid, text, uuid);

-- Igual que en 0102, salvo la columna rol_cuenta del final.
create function public.buscar_candidatos(p_campania_id uuid, p_texto text default null,
                                         p_despues_de uuid default null)
returns table (usuario_id uuid, nombre text, apellido text, email text, estado text,
               campania_actual text, creada_en timestamptz, motivo_bloqueo text, rol_cuenta text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_texto  text := public.normalizar_busqueda(p_texto);
  v_motivo text;
  -- La clave de orden de la cuenta del cursor: (no empieza, sin nombre, nombre, id).
  v_cursor_no_empieza  boolean;
  v_cursor_sin_nombre  boolean;
  v_cursor_nombre      text;
begin
  if auth.uid() is null then
    raise exception 'buscar_candidatos requiere un usuario autenticado'
      using errcode = 'insufficient_privilege';
  end if;

  -- El permiso primero, con los códigos de inscribir_colportor().
  v_motivo := public.motivo_campania_del_coordinador(p_campania_id);
  case v_motivo
    when 'SIN_PERMISO' then
      raise exception 'Solo el coordinador de la campaña puede buscar cuentas para inscribir en ella.'
        using errcode = 'insufficient_privilege';
    when 'CAMPANIA_INEXISTENTE' then
      raise exception 'La campaña no existe.' using errcode = 'CI001';
    when 'CAMPANIA_NO_VIGENTE' then
      raise exception 'La campaña ya terminó. Elegí una campaña en curso o por empezar.'
        using errcode = 'CI002';
    else
      null;
  end case;

  -- La página siguiente. Sin texto, los sugeridos son una sola página.
  if p_despues_de is not null then
    if v_texto is null then
      return;
    end if;
    select not coalesce(strpos(x.n_completo, v_texto) = 1 or strpos(x.n_apellido, v_texto) = 1
                        or strpos(x.n_email, v_texto) = 1, false),
           x.n_completo is null, coalesce(x.n_completo, '')
      into v_cursor_no_empieza, v_cursor_sin_nombre, v_cursor_nombre
      from (select public.normalizar_busqueda(u.nombre || ' ' || u.apellido) as n_completo,
                   public.normalizar_busqueda(u.apellido) as n_apellido,
                   public.normalizar_busqueda(u.email) as n_email
              from public.usuario u
             where u.id = p_despues_de) x;
    if not found then
      raise exception 'No se encontró la última cuenta de la página anterior. Volvé a buscar desde el principio.'
        using errcode = 'invalid_parameter_value';
    end if;
  end if;

  return query
    with candidata as (
      select u.id, u.nombre, u.apellido, u.email, u.created_at, u.suspendido_en,
             public.normalizar_busqueda(u.nombre || ' ' || u.apellido) as n_completo,
             public.normalizar_busqueda(u.apellido) as n_apellido,
             public.normalizar_busqueda(u.email) as n_email
        from public.usuario u
       where u.deleted_at is null
         and exists (select 1 from auth.users au
                      where au.id = u.id and au.confirmed_at is not null)
         and not exists (select 1 from public.campania_colportor cc
                          where cc.campania_id = p_campania_id and cc.usuario_id = u.id
                            and cc.deleted_at is null)
    ),
    -- La clave de orden de la búsqueda: primero las que empiezan con el texto (false < true),
    -- después alfabético, las sin nombre al final, y el id.
    clave as (
      select c.*,
             not coalesce(strpos(c.n_completo, v_texto) = 1 or strpos(c.n_apellido, v_texto) = 1
                          or strpos(c.n_email, v_texto) = 1, false) as no_empieza,
             c.n_completo is null as sin_nombre,
             coalesce(c.n_completo, '') as nombre_orden
        from candidata c
    ),
    elegida as (
      -- Sugeridos: sin texto, las 5 pendientes de asignación más nuevas.
      (select c.*, row_number() over (order by c.created_at desc, c.id desc) as orden
         from clave c
        where v_texto is null
          and public.estado_de_cuenta(c.suspendido_en,
                exists (select 1 from public.inscripciones_no_terminadas_de(c.id))) = 'PENDIENTE_ASIGNACION'
        order by c.created_at desc, c.id desc
        limit 5)
      union all
      -- Búsqueda: de a 10 que contienen el texto, primero las que empiezan con él; después
      -- del cursor, si viene. El coalesce de no_empieza: sin nombre ni apellido, el «empieza»
      -- sería null.
      (select c.*, row_number() over (
                order by c.no_empieza, c.sin_nombre, c.nombre_orden collate "C", c.id) as orden
         from clave c
        where v_texto is not null
          and (strpos(c.n_completo, v_texto) > 0 or strpos(c.n_email, v_texto) > 0)
          and (p_despues_de is null
               or (c.no_empieza, c.sin_nombre, c.nombre_orden collate "C", c.id)
                  > (v_cursor_no_empieza, v_cursor_sin_nombre, v_cursor_nombre collate "C", p_despues_de))
        order by orden
        limit 10)
    )
    select e.id, e.nombre, e.apellido, e.email,
           public.estado_de_cuenta(e.suspendido_en, act.id is not null),
           act.nombre, e.created_at, m.motivo,
           -- 0187: la cuenta es de administración o de coordinación (el criterio de cuenta_tiene_rol(), 0177). Solo
           -- avisa: no saca a nadie de la lista ni cambia motivo_bloqueo.
           case when public.cuenta_tiene_rol(e.id, 'ADMIN') then 'ADMIN'
                when public.cuenta_tiene_rol(e.id, 'COORDINADOR') then 'COORDINADOR'
           end
      from elegida e
      cross join lateral public.motivo_rechazo_inscripcion(p_campania_id, e.id) m
      left join lateral (
        -- La campaña que se muestra: la que bloquea (la misma que nombra inscribir_colportor() en
        -- «Está en la campaña X»); si nada bloquea, la que está en curso; si no, la que empieza antes.
        select c.id, c.nombre
          from public.inscripciones_no_terminadas_de(e.id) v
          join public.campania c on c.id = v.campania_id
         order by (c.id = m.campania_en_conflicto) desc nulls last,
                  (c.fecha_inicio <= public.hoy_montevideo()) desc,
                  c.fecha_inicio, c.id
         limit 1
      ) act on true
     order by e.orden;
end;
$$;

comment on function public.buscar_candidatos(uuid, text, uuid) is
  'HU-CAM-004, vista 23: cuentas para añadir a p_campania_id. Sin texto, los sugeridos (hasta 5 '
  'PENDIENTE_ASIGNACION, o sea sin inscripción en ninguna campaña que no terminó; más nuevas primero, '
  'una sola página); con texto, las que contienen el texto en el nombre completo o el email (sin '
  'mayúsculas ni tildes), primero las que empiezan con él y después alfabético, de a 10 por página: '
  'p_despues_de es el usuario_id de la última de la página anterior. Devuelve estado (ACTIVA con una '
  'inscripción en una campaña que no terminó, 0102), campania_actual (la que bloquea, si no la en '
  'curso, si no la que empieza antes), motivo_bloqueo (el de inscribir_colportor(), null si se '
  'puede) y rol_cuenta (0187: ADMIN o COORDINADOR si la cuenta tiene hoy ese rol, null si no; solo '
  'para avisar en el panel, no bloquea ni filtra). Errores: 42501 sin permiso; CI001 campaña '
  'inexistente; CI002 terminada (una por empezar se busca, 0058); 22023 cursor desconocido (0015).';

-- Los mismos privilegios que le dio la 0015: en una base nueva la imagen da EXECUTE a authenticated sobre toda función nueva,
-- así que se revoca todo y se otorga explícito.
revoke all on function public.buscar_candidatos(uuid, text, uuid) from public, anon, authenticated, service_role;
grant execute on function public.buscar_candidatos(uuid, text, uuid) to authenticated, service_role;
