-- ============================================================================
-- 0120 · Límite de deuda único por campaña: el límite pasa a la campaña y `excede_limite` mide la deuda
--        con el pedido incluido (backend-supabase#156, HU-STK-003, vista 35 «Pedidos y Transferencias»;
--        seguimiento de #100, «Límite ped.»)
--
-- Decisión de Cristian (25/10), «Límite ped.»: el límite es de DEUDA TOTAL CON EL PEDIDO INCLUIDO y hay UNO
-- SOLO POR CAMPAÑA, como el diseño aprobado de la vista 35. Cambia el «por colportor» del 21/10 (docs#69,
-- S64): Marta, coordinadora, fija $U 50.000 para su campaña; Ana debe $U 50.500 y pide $U 10.000: la app le
-- avisa que supera el límite y la deja enviarlo; Marta decide al autorizar. Solo avisa, no bloquea (R-ST06).
--
-- ## Qué cambia
--
--   · `campania.limite_deuda` (bigint, centavos, >= 0; `null` = la campaña no tiene límite). Es de la
--     campaña, no de cada inscripción: vale para los colportores ya inscriptos y para los que se inscriban
--     después. Viaja en el pull de `campania` (la entidad serializa las columnas de la tabla, sin lista
--     aparte) para que la app avise sin conexión.
--   · `campania_colportor.limite_pedido` se SACA, sin migrar datos: era un valor por colportor que no se puede
--     convertir en uno por campaña, la columna nunca tuvo quien la lea y las bases tienen datos simulados
--     hasta diciembre (decisión del issue). Con ella se va de la lista del trigger
--     `campania_colportor_beca_y_limite`, que queda solo para la beca y las metas (mismo candado: ADMIN o
--     coordinador de esa campaña, 42501 para otro). Se conserva su nombre: renombrar un trigger que otros PR
--     abiertos nombran en sus tests solo traería conflictos.
--   · `definir_limite_de_deuda_de_campania(p_campania_id, p_monto) -> (limite_deuda, cambio)`: lo cambia el
--     coordinador de la campaña o un ADMIN (la política de UPDATE de `campania` es solo del ADMIN, así que el
--     coordinador pasa por esta función, como en `definir_alquiler_de_campania`, 0114). p_monto en centavos,
--     >= 0, o null para quitar el límite. Idempotente (`cambio = false` si no cambia nada). Errores: 42501 sin
--     permiso; CZ001 campaña inexistente; CZ011 campaña terminada; 22023 monto negativo. Cada cambio queda en
--     `audit_log` como `limite_de_deuda_de_campania_cambiado` (trigger de `campania`, así queda también si un
--     ADMIN lo cambia con un UPDATE directo): el monto anterior y el nuevo, números o null, nunca texto.
--
-- ## Cómo se mide
--
--   supera_limite_de_deuda_por(p_colportor_id, p_campania_id, p_monto_pedido) -> bigint
--   pedido_excede_limite_de_deuda(p_colportor_id, p_campania_id, p_monto_pedido) -> boolean
--
-- La deuda del colportor con la casa editora (`cuenta_colportor.deuda_total`; sin cuenta = 0) MÁS
-- `p_monto_pedido` contra `campania.limite_deuda`. La primera devuelve cuánto lo supera, o null si no lo
-- supera (justo en el límite NO lo supera) o si la campaña no tiene límite (o no existe). La segunda es
-- «¿lo supera?». `p_monto_pedido` es lo que todavía NO está en la deuda: el total de un pedido por autorizar;
-- 0 para uno ya autorizado (su monto ya está en `deuda_total`, que lo suma al autorizar, 0112). Son internas
-- (sin EXECUTE para nadie con JWT: reciben un colportor cualquiera): las llaman las funciones SECURITY
-- DEFINER que arman la bandeja y que crean el pedido.
--
-- ## De quién es la campaña
--
-- `pedido_casa_editora` no tiene campaña, y un colportor puede estar inscripto en varias a lo largo del
-- tiempo. Por eso la función recibe la campaña: quien arma el pedido (#102, desde la inscripción en curso del
-- colportor) o abre la bandeja (el coordinador, desde la campaña que mira) la nombra.
--
-- ## Lo que NO hace
--
--   · No bloquea nada ni escribe `pedido_casa_editora.excede_limite`: quien envía el pedido (#102) lo calcula
--     con la función (o la app, sin conexión, con el límite del pull) y lo guarda; un trigger que lo pisara
--     en el servidor rompería los pedidos que otros PR cargan con ese valor. Tampoco hay UPDATE masivo: en las
--     tablas vacías no hay pedido que recalcular.
--   · No toca `pedido_contexto` (0112): esa función vive en el PR 179 (#104) y todavía no está en develop. Cuando
--     llegue, suma `limite_deuda` y `supera_limite_por` con `supera_limite_de_deuda_por()` (parámetro
--     opcional `p_campania_id`): un `create or replace` de seguimiento (ver el cuerpo del PR).
--
-- ## Para otros repos
--
--   · front-coordinadores-web (vista 35, «Editar el límite»): POST /rest/v1/rpc/definir_limite_de_deuda_de_campania
--     con { p_campania_id, p_monto }; el límite actual es `limite_deuda` de la campaña (SELECT o pull).
--   · front-colportores-mobile (#387, #102): `campania.limite_deuda` baja con la campaña (null = sin límite);
--     `campania_colportor.limite_pedido` desaparece del pull de la inscripción: la tabla local tiene que
--     dejar de leerla.
--   · docs-organizacion: `esquema-datos.md` (campos de `campania` y de `campania_colportor`, `excede_limite`),
--     HU-STK-003 (de «por colportor» a «uno por campaña») y S64, en un issue aparte.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. campania.limite_deuda
-- ----------------------------------------------------------------------------

alter table public.campania
  add column limite_deuda bigint;

alter table public.campania
  add constraint campania_limite_deuda_check
  check (limite_deuda is null or limite_deuda >= 0);

comment on column public.campania.limite_deuda is
  'Límite de deuda de la campaña en centavos (decisión de Cristian, 25/10, «Límite ped.»): uno solo para todos '
  'sus colportores, medido contra la deuda total con la casa editora MÁS el pedido que se envía. null = sin '
  'límite. Solo AVISA: no bloquea ni al colportor al armar el pedido ni al coordinador al autorizarlo (R-ST06). '
  'Lo cambian el coordinador de la campaña o el ADMIN con definir_limite_de_deuda_de_campania().';

-- ----------------------------------------------------------------------------
-- 2. Se va el límite por inscripción
-- ----------------------------------------------------------------------------

-- Primero el trigger sin la columna (un trigger con lista de columnas depende de ellas), después la columna
-- (su CHECK se va con ella). Igual que en 0117, salvo que `limite_pedido` sale de la lista y el mensaje no
-- lo nombra.
create or replace function public.tg_campania_colportor_beca_y_limite()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    return new;
  end if;

  if new.tipo_beca is not distinct from old.tipo_beca
     and new.meta_libros is not distinct from old.meta_libros
     and new.meta_monto_ces is not distinct from old.meta_monto_ces then
    return new;
  end if;

  if public.tiene_rol('ADMIN')
     or (public.tiene_rol('COORDINADOR')
         and exists (select 1 from public.campania c
                      where c.id = new.campania_id and c.coordinador_id = auth.uid())) then
    return new;
  end if;

  raise exception 'La beca y la meta las fija el coordinador de la campaña'
    using errcode = '42501';
end;
$$;

comment on function public.tg_campania_colportor_beca_y_limite() is
  'BEFORE UPDATE OF tipo_beca, meta_libros, meta_monto_ces en campania_colportor (0067, 0117, 0120): solo el '
  'ADMIN o el coordinador de esa campaña los cambian con un JWT (42501); el servidor, sin restricción. El '
  'límite de deuda ya no es de la inscripción: es de la campaña (campania.limite_deuda).';

drop trigger campania_colportor_beca_y_limite on public.campania_colportor;

create trigger campania_colportor_beca_y_limite
  before update of tipo_beca, meta_libros, meta_monto_ces on public.campania_colportor
  for each row execute function public.tg_campania_colportor_beca_y_limite();

alter table public.campania_colportor
  drop column limite_pedido;

comment on column public.pedido_casa_editora.excede_limite is
  'true si la deuda del colportor con la casa editora al enviar el pedido, MÁS el total del pedido, superaba '
  'campania.limite_deuda (0120, decisión de Cristian, 25/10). Solo informa, no bloquea. Quien envía el pedido '
  '(#102) lo calcula con pedido_excede_limite_de_deuda() o, sin conexión, la app con el límite del pull.';

-- ----------------------------------------------------------------------------
-- 3. El cambio del límite queda en audit_log
-- ----------------------------------------------------------------------------

create function public.tg_campania_limite_deuda_auditar()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  -- Quién: auth.uid() lo pone auditoria.registrar(). El detalle, solo los dos montos (centavos o null).
  perform auditoria.registrar(
    'limite_de_deuda_de_campania_cambiado', 'campania', new.id, null,
    jsonb_build_object('monto_anterior', old.limite_deuda, 'monto_nuevo', new.limite_deuda));
  return null;
end;
$$;

comment on function public.tg_campania_limite_deuda_auditar() is
  'AFTER UPDATE OF limite_deuda en campania (0120, backend-supabase#156): deja el evento '
  'limite_de_deuda_de_campania_cambiado en audit_log con el monto anterior y el nuevo.';

revoke all on function public.tg_campania_limite_deuda_auditar() from public, anon, authenticated, service_role;

create trigger campania_limite_deuda_auditar
  after update of limite_deuda on public.campania
  for each row
  when (old.limite_deuda is distinct from new.limite_deuda)
  execute function public.tg_campania_limite_deuda_auditar();

-- ----------------------------------------------------------------------------
-- 4. definir_limite_de_deuda_de_campania
-- ----------------------------------------------------------------------------

create function public.definir_limite_de_deuda_de_campania(p_campania_id uuid, p_monto bigint)
returns table (limite_deuda bigint, cambio boolean)
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
    raise exception 'Solo el coordinador de la campaña o un administrador puede cambiar su límite de deuda. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_motivo = 'CAMPANIA_TERMINADA' then
    raise exception 'La campaña ya terminó y su límite de deuda queda como estaba. Elegí una campaña en curso.'
      using errcode = 'CZ011';
  end if;
  perform public.lanzar_motivo_mapa(v_motivo);

  if p_monto is not null and p_monto < 0 then
    raise exception 'El límite de deuda no puede ser negativo. Escribí un monto de cero o más, o dejalo vacío si la campaña no tiene límite.'
      using errcode = 'invalid_parameter_value';
  end if;

  -- Con candado: el doble toque y dos coordinadores se serializan acá.
  select c.limite_deuda into v_anterior
    from public.campania c
   where c.id = p_campania_id
     for update;

  if v_anterior is distinct from p_monto then
    update public.campania c set limite_deuda = p_monto where c.id = p_campania_id;
  end if;

  return query select p_monto, (v_anterior is distinct from p_monto);
end;
$$;

comment on function public.definir_limite_de_deuda_de_campania(uuid, bigint) is
  'Vista 35, HU-STK-003 (0120, backend-supabase#156): el coordinador de la campaña (o un ADMIN) fija el límite '
  'de deuda único de la campaña (centavos, >= 0; null = sin límite). Solo avisa: no bloquea pedidos. Idempotente '
  '(cambio = false si no cambia nada). El cambio queda en audit_log (trigger campania_limite_deuda_auditar). '
  'Errores: 42501 sin permiso; CZ001 campaña inexistente; CZ011 campaña terminada; 22023 monto negativo.';

revoke all on function public.definir_limite_de_deuda_de_campania(uuid, bigint)
  from public, anon, authenticated, service_role;
grant execute on function public.definir_limite_de_deuda_de_campania(uuid, bigint) to authenticated;

-- ----------------------------------------------------------------------------
-- 5. Cuánto supera el límite un pedido
-- ----------------------------------------------------------------------------

create function public.supera_limite_de_deuda_por(p_colportor_id uuid, p_campania_id uuid, p_monto_pedido bigint)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select case
           when c.limite_deuda is null then null
           when coalesce(cu.deuda_total, 0) + coalesce(p_monto_pedido, 0) > c.limite_deuda
             then coalesce(cu.deuda_total, 0) + coalesce(p_monto_pedido, 0) - c.limite_deuda
         end
    from public.campania c
    left join public.cuenta_colportor cu
           on cu.usuario_id = p_colportor_id and cu.deleted_at is null
   where c.id = p_campania_id and c.deleted_at is null
$$;

comment on function public.supera_limite_de_deuda_por(uuid, uuid, bigint) is
  'Interna (0120, backend-supabase#156): cuánto supera el límite de deuda de la campaña la deuda del colportor '
  'con la casa editora (cuenta_colportor.deuda_total; sin cuenta = 0) MÁS p_monto_pedido (lo que todavía no está '
  'en la deuda; 0 para un pedido ya autorizado), en centavos. null si no lo supera (justo en el límite no), si '
  'la campaña no tiene límite o si no existe.';

revoke all on function public.supera_limite_de_deuda_por(uuid, uuid, bigint)
  from public, anon, authenticated, service_role;

create function public.pedido_excede_limite_de_deuda(p_colportor_id uuid, p_campania_id uuid, p_monto_pedido bigint)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.supera_limite_de_deuda_por(p_colportor_id, p_campania_id, p_monto_pedido) is not null
$$;

comment on function public.pedido_excede_limite_de_deuda(uuid, uuid, bigint) is
  'Interna (0120, backend-supabase#156): el valor de pedido_casa_editora.excede_limite para un pedido de '
  'p_monto_pedido centavos: true si la deuda con la casa editora más el pedido supera el límite de la campaña. '
  'false sin límite. Solo informa, no bloquea.';

revoke all on function public.pedido_excede_limite_de_deuda(uuid, uuid, bigint)
  from public, anon, authenticated, service_role;
