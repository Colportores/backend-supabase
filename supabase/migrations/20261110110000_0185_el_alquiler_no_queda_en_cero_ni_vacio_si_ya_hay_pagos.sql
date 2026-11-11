-- ============================================================================
-- 0185 · El alquiler de la campaña no puede quedar en 0 ni vacío si ya hay pagos
--        (backend-supabase#260, HU-CAM-002, vista 36 «Editar» del alquiler; decisión de Cristian del 10/11, «Alquiler a 0»:
--        «Bloquear si ya hay pagos», en front-coordinadores-web#165)
--
-- ## El caso
--
-- Marta, coordinadora, está en «Cuentas» del panel a mitad de la campaña y varios colportores ya pagaron el alquiler. Toca
-- «Editar» junto a «Alquiler de la campaña», pone 0 (o lo vacía) y guarda. Hasta ahora el servidor lo aceptaba y todo lo
-- pagado quedaba «por decidir» (0159/0167), un caso que Cristian dijo que no existe: no se deja de cobrar alquiler.
--
-- ## Qué cambia
--
--   definir_alquiler_de_campania(p_campania_id, p_monto) -> (alquiler_monto, cambio)      (0114, misma firma)
--
-- Rechaza `p_monto = 0` o `null` con el código nuevo **CZ017** cuando la campaña ya tiene pagos de alquiler: algún depósito
-- de concepto ALQUILER de esa campaña **vivo**, de cualquier colportor (también de uno dado de baja). Vivo = no dado de baja
-- (`deleted_at`), no anulado porque se le devolvió a la persona (`anulado_at`, 0167) y no rechazado: ni el retiro rechazado
-- por el coordinador (`rechazado_en`, 0152) ni uno sin validar con su comprobante RECHAZADO. Todo lo demás cuenta como pago:
-- los validados y los por validar (sin comprobante o con el comprobante PENDIENTE) y, ante la duda (un estado que no encaja),
-- también: se bloquea.
--
-- Sigue permitido:
--   · cambiar el monto a otro mayor que 0 en cualquier momento (lo pagado de más sigue la regla de la 0152);
--   · poner 0 o vaciarlo mientras nadie pagó (ningún depósito vivo de alquiler en la campaña).
--
-- El chequeo corre después del `for update` sobre la campaña que ya serializaba el doble toque y dos coordinadores. Además,
-- ese candado choca con el `FOR KEY SHARE` que toma la FK `deposito.campania_id` al cargar un depósito de esa campaña: un
-- depósito que entra a la vez espera, o es visto por el chequeo (read committed: la consulta de después del candado ve lo
-- que ya se confirmó).
--
-- El orden de los errores no cambia: 42501 sin permiso, CZ011 campaña terminada, CZ001 inexistente, 22023 monto negativo,
-- y recién con la campaña tomada, CZ017. Al rechazar no se escribe nada (ni el monto, ni el registro en audit_log).
--
-- ## Lo que NO hace
--
--   · No toca el UPDATE directo que la política le deja al ADMIN sobre `campania` (fuera del pedido del issue): la regla vive
--     en la función que usa el panel.
--   · No toca lo ya pagado ni las decisiones de alquiler de las bajas (0167/0181).
--
-- ## Los datos
--
-- Solo reemplaza el cuerpo de una función; no toca filas. Lo prueba supabase/tests/0185_… .
--
-- ## Para otros repos
--
--   · front-coordinadores-web#169 (vista 36, «Editar» del alquiler): CZ017 trae el aviso que guía («Ya hay pagos de alquiler
--     en esta campaña…»); el panel lo muestra y deja el campo con el monto anterior.
--   · docs-organizacion#172: el comentario de la función, `esquema-datos.md` y HU-CAM-002 (los toma el carril de docs).
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

create or replace function public.definir_alquiler_de_campania(p_campania_id uuid, p_monto bigint)
returns table (alquiler_monto bigint, cambio boolean)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_motivo    text;
  v_anterior  bigint;
begin
  -- El permiso, antes de mirar nada más.
  v_motivo := public.motivo_mapa_de_campania(p_campania_id);
  if v_motivo = 'SIN_PERMISO' then
    raise exception 'Solo el coordinador de la campaña o un administrador puede cambiar su alquiler. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_motivo = 'CAMPANIA_TERMINADA' then
    raise exception 'La campaña ya terminó y su alquiler queda como estaba. Elegí una campaña en curso.'
      using errcode = 'CZ011';
  end if;
  perform public.lanzar_motivo_mapa(v_motivo);

  if p_monto is not null and p_monto < 0 then
    raise exception 'El alquiler no puede ser negativo. Escribí un monto de cero o más, o dejalo vacío si la campaña no cobra alquiler.'
      using errcode = 'invalid_parameter_value';
  end if;

  -- Con candado: el doble toque y dos coordinadores se serializan acá (y un depósito que entra a la vez, por la FK).
  select c.alquiler_monto into v_anterior
    from public.campania c
   where c.id = p_campania_id
     for update;

  -- «Alquiler a 0» (0185): con pagos de alquiler vivos, la campaña no puede quedar sin alquiler ni en cero. No cuentan los
  -- dados de baja, los anulados (devueltos, 0167), los retiros rechazados (0152) ni los sin validar con el comprobante
  -- rechazado; todo lo demás, sí (ante la duda, se bloquea).
  if coalesce(p_monto, 0) = 0
     and exists (
       select 1
         from public.deposito dep
         left join public.ticket t on t.id = dep.ticket_id
        where dep.campania_id = p_campania_id
          and dep.concepto = 'ALQUILER'
          and dep.deleted_at is null
          and dep.anulado_at is null
          and dep.rechazado_en is null
          and (dep.validado_en is not null or t.estado is distinct from 'RECHAZADO')) then
    raise exception 'Ya hay pagos de alquiler en esta campaña, así que no puede quedar sin alquiler ni en cero. Podés cambiarlo por otro monto mayor que cero.'
      using errcode = 'CZ017';
  end if;

  if v_anterior is distinct from p_monto then
    update public.campania c set alquiler_monto = p_monto where c.id = p_campania_id;
  end if;

  return query select p_monto, (v_anterior is distinct from p_monto);
end;
$$;

comment on function public.definir_alquiler_de_campania(uuid, bigint) is
  'Vista 36, HU-CAM-002 (0114, 0185): el coordinador de la campaña (o un ADMIN) cambia el monto fijo del alquiler '
  '(centavos, >= 0; null = la campaña no cobra). Vale para los inscriptos y los que se inscriban después; lo ya depositado '
  'no se toca y el saldo se recalcula. Con pagos de alquiler vivos en la campaña (no dados de baja, anulados ni '
  'rechazados) no puede quedar en 0 ni en null (decisión «Alquiler a 0», 10/11). Idempotente (cambio = false si no cambia '
  'nada). El cambio queda en audit_log (trigger campania_alquiler_auditar). Errores: 42501 sin permiso; CZ001 campaña '
  'inexistente; CZ011 campaña terminada; 22023 monto negativo; CZ017 0 o vacío con pagos de alquiler.';
