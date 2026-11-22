-- ============================================================================
-- 0103 · backend-supabase#140 · El tope de la nota del acompañamiento pasa de 280 a 500 caracteres
-- ============================================================================
-- La 0100 (PR #160) puso 280 caracteres como tope de la nota del acompañamiento porque la decisión
-- «Nota acomp.» (23/10) dice «con tope» sin número. El 26/10 el agente de decisiones lo fijó en 500
-- (regla R2 del mapa: el mismo tope de `venta.motivo_monto_manual`, 0071, y de la nota de la casa):
-- `pendientes/backend-supabase-140-impl-261026-1227.md`, P1.
--
-- La 0100 ya está en develop, así que no se edita: esta migración cambia el CHECK de la columna y vuelve a
-- crear `agregar_acompaniamiento()` (misma firma, mismos permisos) con el tope nuevo y su mensaje. Como el
-- tope sube, ninguna nota guardada deja de cumplirlo y no se toca ninguna fila.
-- ============================================================================

alter table public.jornada drop constraint jornada_acompaniamiento_nota_forma;
alter table public.jornada
  add constraint jornada_acompaniamiento_nota_forma
    check (acompaniamiento_nota is null
           or (acompaniamiento_origen = 'COORDINADOR'
               and acompaniamiento_nota ~ '^\S(.*\S)?$'
               and char_length(acompaniamiento_nota) <= 500));

comment on column public.jornada.acompaniamiento_nota is
  'Nota opcional del coordinador sobre el acompañamiento (0100, #140; tope de 500 caracteres desde la 0103): '
  'sin datos de clientes (lo dice el aviso del panel; no se puede validar). Solo con origen COORDINADOR. Lo '
  'pone el servidor; el push la descarta.';

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
  'Vista 33, HU-JOR-004 (0043, backend-supabase#97; 0073, #136; 0100 y 0103, #140): el coordinador de la campaña '
  '(o un ADMIN) registra el acompañamiento de una jornada ya cerrada: el suyo («Yo», sin p_acompaniante_id) '
  'o el de otro colportor inscripto en la campaña, con una nota opcional (hasta 500 caracteres). Deja '
  'jornada.acompaniante_id, acompaniamiento_origen = COORDINADOR y la nota, y el evento '
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
