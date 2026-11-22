-- ============================================================================
-- 0184 · La cola de retiros de la campaña para «Validar tickets» (vista 29)
--        (backend-supabase#261, HU-COB-008; decisión de Cristian del 10/11, «Conectar 29»; lo consume
--        front-coordinadores-web#170)
--
-- ## El caso
--
-- Ana le da en mano a su coordinadora lo que cobró y lo registra en el teléfono como retiro (depósito con destino
-- `RETIRO_COORDINADOR`, sin ticket). Marta, coordinadora, abre «Validar tickets» en el panel para confirmarlo
-- (`confirmar_retiro`, 0129/0152) o rechazarlo (`rechazar_retiro`, 0152). Los depósitos con ticket salen de
-- `tickets_de_campania` (0113/0131), pero ninguna RPC listaba los retiros: la coordinadora no lee `deposito` (RLS).
--
-- ## Qué suma
--
--   retiros_de_campania(p_campania_id, p_estado, p_colportor_id, p_ciudad_id, p_desde, p_hasta, p_limite,
--                       p_desplazamiento)
--     -> (deposito_id, colportor_id, nombre, apellido, de_baja, ciudad_id, ciudad_nombre, departamento,
--         monto, fecha, concepto, estado, motivo_rechazo, subido_en, revisado_por, revisado_en, anulado_en)
--
-- Los mismos filtros, paginado y permiso que `tickets_de_campania` (regla R1: solo suma; `tickets_de_campania` no
-- cambia):
--
--   · Qué retiros: depósitos vivos (`deleted_at` null) con destino `RETIRO_COORDINADOR` de los colportores inscriptos
--     en la campaña (también los dados de baja: lo que cargaron antes de irse sigue por confirmar). Un retiro es de
--     la campaña que lo confirma, la misma regla de `retiro_para_confirmar` (0129, 0175): su `campania_id` o, sin
--     ella, la de la inscripción vigente en su fecha (`campania_del_ticket`). Así todo lo que sale acá se puede
--     confirmar o rechazar con la misma campaña, y nada que se pueda confirmar queda afuera.
--   · `estado`: PENDIENTE (por confirmar: ni validado ni rechazado), VALIDADO (confirmado: `validado_en`) o RECHAZADO
--     (`rechazado_en`, con `motivo_rechazo`). Los tres de `tickets_de_campania`: el panel los muestra igual (en un
--     retiro, VALIDADO es «Confirmado»).
--   · `revisado_por` / `revisado_en`: quién y cuándo lo confirmó o rechazó (null mientras está por confirmar).
--   · `anulado_en`: un pago de alquiler confirmado y después devuelto a la persona (0167) sigue confirmado, con la
--     fecha en que se anuló; null en los demás.
--   · `subido_en`: cuándo llegó al servidor (`created_at`); `fecha`, cuándo entregó el efectivo.
--   · La ciudad, la de la zona actual de su inscripción (null sin zona o con la inscripción de baja), como en
--     `tickets_de_campania`.
--   · Orden: los por confirmar primero y, entre ellos, el que espera hace más; después, el más nuevo primero. Como la
--     cola de tickets.
--   · Filtros opcionales: estado, colportor, ciudad, y la fecha del retiro (día de Montevideo, ambos incluidos).
--     Hasta 500 filas por página (`p_limite`, `p_desplazamiento`).
--
-- Sin datos de clientes: el retiro es plata de la colportora, no de una venta.
--
-- ## Permisos
--
-- Los de `tickets_de_campania`: `motivo_mapa_de_campania()` (0175), 42501 sin sesión o sin ser ADMIN ni uno de los
-- coordinadores de ESA campaña; CZ001 campaña inexistente. Una campaña terminada se lee (para cerrar lo que quedó por
-- confirmar). SECURITY DEFINER, `search_path` vacío, VOLATILE (llama a `lanzar_motivo_mapa`), EXECUTE solo para
-- `authenticated`.
--
-- ## Errores
--
--   42501  sin permiso.
--   CZ001  la campaña no existe.
--   22023  filtro inválido: estado fuera de PENDIENTE/VALIDADO/RECHAZADO, límite fuera de 1 a 500, desplazamiento
--          negativo o desde posterior a hasta.
--
-- ## Los datos
--
-- Solo una función nueva; no toca filas. Lo prueba supabase/tests/0184_retiros_de_campania_test.sql. Forward-only.
--
-- ## Para otros repos
--
--   · front-coordinadores-web#170: la vista 29 llama `retiros_de_campania(campania)` junto con `tickets_de_campania`
--     y arma la cola con las dos (el id que pasa a `validacion_de_retiro`, `confirmar_retiro` y `rechazar_retiro` es
--     `deposito_id`).
--   · docs-organizacion: la fila de la RPC en el contrato (entrada «Sin publicar»).
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

create function public.retiros_de_campania(
  p_campania_id uuid,
  p_estado text default null,
  p_colportor_id uuid default null,
  p_ciudad_id uuid default null,
  p_desde date default null,
  p_hasta date default null,
  p_limite integer default 200,
  p_desplazamiento integer default 0)
returns table (deposito_id uuid, colportor_id uuid, nombre text, apellido text, de_baja boolean,
               ciudad_id uuid, ciudad_nombre text, departamento text,
               monto bigint, fecha timestamptz, concepto text,
               estado text, motivo_rechazo text, subido_en timestamptz,
               revisado_por uuid, revisado_en timestamptz, anulado_en timestamptz)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_motivo text;
begin
  -- El permiso, antes de mirar nada más (como tickets_de_campania).
  v_motivo := public.motivo_mapa_de_campania(p_campania_id);
  if v_motivo = 'SIN_PERMISO' then
    raise exception 'Solo el coordinador de la campaña o un administrador puede ver sus retiros. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_motivo is distinct from 'CAMPANIA_TERMINADA' then
    perform public.lanzar_motivo_mapa(v_motivo);
  end if;

  if p_estado is not null and p_estado not in ('PENDIENTE', 'VALIDADO', 'RECHAZADO') then
    raise exception 'El estado del retiro es PENDIENTE, VALIDADO o RECHAZADO.'
      using errcode = '22023';
  end if;
  if p_limite is null or p_limite < 1 or p_limite > 500 then
    raise exception 'El límite de retiros es de 1 a 500.'
      using errcode = '22023';
  end if;
  if p_desplazamiento is null or p_desplazamiento < 0 then
    raise exception 'El desplazamiento no puede ser negativo.'
      using errcode = '22023';
  end if;
  if p_desde is not null and p_hasta is not null and p_desde > p_hasta then
    raise exception 'La fecha desde no puede ser posterior a la fecha hasta.'
      using errcode = '22023';
  end if;

  return query
    with inscripcion as materialized (
      -- Una por colportor de la campaña, también la dada de baja. La ciudad sale de la zona actual; una zona, una
      -- ciudad de campaña o una inscripción dadas de baja no cuentan (la regla de tickets_de_campania).
      select i.usuario_id,
             (i.deleted_at is not null) as baja,
             ci.ciudad_id as ciudad_k
        from public.campania_colportor i
        left join public.zona z
               on z.id = i.zona_id and z.deleted_at is null and i.deleted_at is null
        left join public.campania_ciudad ci
               on ci.id = z.campania_ciudad_id and ci.deleted_at is null
       where i.campania_id = p_campania_id
    ),
    retiro as (
      select d.id, d.colportor_id, d.monto, d.fecha, d.concepto, d.motivo_rechazo, d.created_at,
             d.validado_por, d.validado_en, d.rechazado_por, d.rechazado_en, d.anulado_at,
             case when d.rechazado_en is not null then 'RECHAZADO'
                  when d.validado_en is not null then 'VALIDADO'
                  else 'PENDIENTE' end as estado_k
        from inscripcion ins
        join public.deposito d
          on d.colportor_id = ins.usuario_id
         and d.destino = 'RETIRO_COORDINADOR'
         and d.deleted_at is null
         -- Un retiro, una campaña: la que lo confirma (retiro_para_confirmar, 0175).
         and coalesce(d.campania_id, public.campania_del_ticket(d.colportor_id, d.fecha)) = p_campania_id
    )
    select r.id,
           ins.usuario_id,
           usr.nombre,
           usr.apellido,
           ins.baja,
           ciu.id,
           ciu.nombre,
           ciu.departamento,
           r.monto,
           r.fecha,
           r.concepto,
           r.estado_k,
           r.motivo_rechazo,
           r.created_at,
           coalesce(r.validado_por, r.rechazado_por),
           coalesce(r.validado_en, r.rechazado_en),
           r.anulado_at
      from retiro r
      join inscripcion ins on ins.usuario_id = r.colportor_id
      join public.usuario usr on usr.id = ins.usuario_id
      left join public.ciudad ciu on ciu.id = ins.ciudad_k
     where (p_estado is null or r.estado_k = p_estado)
       and (p_colportor_id is null or ins.usuario_id = p_colportor_id)
       and (p_ciudad_id is null or ciu.id = p_ciudad_id)
       and (p_desde is null or public.hoy_montevideo(r.fecha) >= p_desde)
       and (p_hasta is null or public.hoy_montevideo(r.fecha) <= p_hasta)
     -- Los por confirmar primero y, entre ellos, el que espera hace más; después, el más nuevo primero.
     order by (r.estado_k <> 'PENDIENTE'),
              case when r.estado_k = 'PENDIENTE' then r.created_at end,
              r.created_at desc, r.id
     limit p_limite offset p_desplazamiento;
end;
$$;

comment on function public.retiros_de_campania(uuid, text, uuid, uuid, date, date, integer, integer) is
  'Vista 29, HU-COB-008 (0184, backend-supabase#261): los retiros por el coordinador (deposito RETIRO_COORDINADOR, sin '
  'ticket) de los colportores inscriptos en la campaña (también los dados de baja), en la campaña que los confirma '
  '(campania_id o, sin ella, la de la inscripción de su fecha, como retiro_para_confirmar). Por retiro: el colportor, la '
  'ciudad de su zona actual (null = sin ciudad), monto, fecha, concepto, estado (PENDIENTE = por confirmar, VALIDADO = '
  'confirmado, RECHAZADO), motivo del rechazo, cuándo llegó (subido_en), quién y cuándo lo confirmó o rechazó y, si era '
  'un pago de alquiler devuelto, cuándo se anuló. Filtros opcionales: estado, colportor, ciudad y fecha del retiro (día '
  'de Montevideo, ambos incluidos). Los por confirmar primero (el más viejo antes). Hasta 500 filas (p_limite, '
  'p_desplazamiento). Sin datos de clientes. Errores: 42501 sin permiso; CZ001 campaña inexistente; 22023 filtro '
  'inválido. Una campaña terminada se lee.';

revoke all on function public.retiros_de_campania(uuid, text, uuid, uuid, date, date, integer, integer)
  from public, anon, authenticated, service_role;
grant execute on function public.retiros_de_campania(uuid, text, uuid, uuid, date, date, integer, integer)
  to authenticated;
