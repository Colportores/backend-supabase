-- ============================================================================
-- 0009 · La zona del colportor vive solo en su inscripción (backend-supabase#23)
--
-- Regla 3 del cambio de modelo del 29/09 (vistas de Claude Design «Vistas colportaje»):
-- campania_colportor.zona_id es el ÚNICO lugar donde se guarda la zona de un colportor
-- (null = «sin zona»), y esa zona tiene que ser de una ciudad de la misma campaña. Resuelve
-- la «zona directa» (usuario.zona_id) que quedó abierta en #18 y #20.
--
-- ## Qué cambia
--
--   · usuario.zona_id se va, con su FK, su trigger (usuario_zona_servidor) y la rama de
--     mis_zonas() que la leía. Antes se migran los datos (abajo).
--   · Trigger campania_colportor_zona_valida (BEFORE INSERT/UPDATE): la zona de una
--     inscripción es de una ciudad viva de la misma campaña y no está dada de baja. Vale
--     también fuera de asignar_zona() (seed, service_role, un job), y también al reactivar
--     una inscripción dada de baja (propuesta: se rechaza la reactivación con una zona que ya
--     no sirve, en vez de borrarle la zona en silencio; el aviso dice cómo reactivarla sin
--     zona).
--   · CZ004 dice «La zona no existe o ya se dio de baja. Recargá el mapa.», como el mapa (0008).
--   · mis_zonas(): solo las zonas de inscripciones vigentes que siguen vivas (zona y ciudad
--     de la campaña). Una zona dada de baja ya no abre nada (pendiente de #21).
--   · asignar_zona(): CZ006 dice de qué campaña elegir; CZ005 dice qué hacer.
--   · baja_zona(): deja de contar usuario.zona_id como asignación.
--
-- ## Migración de usuario.zona_id (criterio 2: nada se pierde en silencio)
--
-- Por cada usuario con zona directa:
--   · tiene una inscripción viva en la campaña de esa zona SIN zona → se copia ahí;
--   · esa inscripción ya tiene esa misma zona → no hay nada que copiar;
--   · no tiene inscripción viva en esa campaña (el aviso distingue si no tiene ninguna o si
--     está dada de baja), la inscripción tiene OTRA zona, o habría que
--     copiar una zona dada de baja (o de una ciudad quitada de la campaña) → la migración
--     aborta y lista cada caso con qué hacer.
-- Además aborta si alguna inscripción viva ya tiene una zona de otra campaña: con la regla
-- nueva esa fila quedaría inválida.
--
-- ## CZ005 y CZ006 (propuesta: NO unificarlos)
--
--   CZ006  la zona es de otra campaña. Qué hacer: elegir una zona de esta campaña.
--   CZ005  la zona es de esta campaña, pero su ciudad se quitó de ella (campania_ciudad
--          dada de baja). Qué hacer: elegir una zona de otra ciudad, o volver a agregar la
--          ciudad. Es otro caso y otra acción, así que conviene que el panel los distinga.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Qué no se puede migrar: se revisa todo antes de cambiar nada
-- ----------------------------------------------------------------------------

do $$
declare
  v_problemas text;
begin
  select string_agg(x.linea, E'\n' order by x.linea)
    into v_problemas
    from (
      -- Zona directa que no tiene a dónde ir.
      select format('  · %s (%s), zona directa «%s» de «%s»: %s',
               coalesce(nullif(btrim(concat_ws(' ', u.nombre, u.apellido)), ''), 'usuario sin nombre'),
               u.id, z.nombre, c.nombre,
               case
                 when ins.id is null and baja.id is not null then
                   'su inscripción en esa campaña está dada de baja, e inscribir_colportor no la reactiva (CI008). Si ya no trabaja en esa campaña, sacale la zona (usuario.zona_id = null); si sigue, reactivá la inscripción como service_role (campania_colportor.deleted_at = null). Después volvé a aplicar la migración.'
                 when ins.id is null then
                   'no tiene una inscripción en esa campaña. Inscribilo (inscribir_colportor) o sacale la zona (usuario.zona_id = null), y volvé a aplicar la migración.'
                 when ins.zona_id is not null then
                   format('su inscripción en esa campaña ya tiene otra zona («%s»). Elegí cuál queda (en la inscripción) y sacale la zona directa (usuario.zona_id = null), y volvé a aplicar la migración.',
                          zi.nombre)
                 when z.deleted_at is not null then
                   'la zona está dada de baja. Sacale la zona (usuario.zona_id = null) o reactivá la zona, y volvé a aplicar la migración.'
                 else
                   'la ciudad de la zona ya no está en la campaña. Sacale la zona (usuario.zona_id = null) o volvé a agregar la ciudad, y volvé a aplicar la migración.'
               end) as linea
        from public.usuario u
        join public.zona z on z.id = u.zona_id
        join public.campania_ciudad cc on cc.id = z.campania_ciudad_id
        join public.campania c on c.id = cc.campania_id
        left join public.campania_colportor ins
          on ins.usuario_id = u.id and ins.campania_id = cc.campania_id and ins.deleted_at is null
        -- La inscripción dada de baja (una sola: unique (campania_id, usuario_id)): otro qué hacer.
        left join public.campania_colportor baja
          on baja.usuario_id = u.id and baja.campania_id = cc.campania_id and baja.deleted_at is not null
        left join public.zona zi on zi.id = ins.zona_id
       -- Si la inscripción ya tiene esa misma zona no hay nada que copiar: no es un problema.
       where ins.id is null
          or (ins.zona_id is not null and ins.zona_id <> u.zona_id)
          or (ins.zona_id is null and (z.deleted_at is not null or cc.deleted_at is not null))
      union all
      -- Inscripción viva cuya zona es de otra campaña: la regla nueva la dejaría inválida.
      select format('  · %s (%s), inscripción en «%s»: su zona «%s» es de otra campaña («%s»). Asignale una zona de «%s» o dejala sin zona (zona_id = null), y volvé a aplicar la migración.',
               coalesce(nullif(btrim(concat_ws(' ', u.nombre, u.apellido)), ''), 'usuario sin nombre'),
               u.id, c.nombre, z.nombre, cz.nombre, c.nombre)
        from public.campania_colportor ins
        join public.usuario u on u.id = ins.usuario_id
        join public.campania c on c.id = ins.campania_id
        join public.zona z on z.id = ins.zona_id
        join public.campania_ciudad cc on cc.id = z.campania_ciudad_id
        join public.campania cz on cz.id = cc.campania_id
       where ins.deleted_at is null and cc.campania_id <> ins.campania_id
    ) x;

  if v_problemas is not null then
    raise exception using
      message = 'La migración 0009 (la zona vive solo en la inscripción) no se aplicó: hay zonas '
                'de colportores que no se pueden pasar a su inscripción sin perder o inventar una '
                'asignación. No se cambió nada.',
      detail  = v_problemas,
      hint    = 'Resolvé cada caso de la lista y volvé a aplicar la migración.';
  end if;
end
$$;

-- ----------------------------------------------------------------------------
-- 2. usuario.zona_id → campania_colportor.zona_id
-- ----------------------------------------------------------------------------

-- Corre como el dueño de la migración, no como `authenticated`: la guarda de 0006
-- (zona_id solo por asignar_zona) no aplica.
update public.campania_colportor ins
   set zona_id = u.zona_id
  from public.usuario u
  join public.zona z on z.id = u.zona_id
  join public.campania_ciudad cc on cc.id = z.campania_ciudad_id
 where ins.usuario_id = u.id
   and ins.campania_id = cc.campania_id
   and ins.deleted_at is null
   and ins.zona_id is null
   and z.deleted_at is null
   and cc.deleted_at is null;

-- ----------------------------------------------------------------------------
-- 3. Lo que leía usuario.zona_id, antes de borrarla
-- ----------------------------------------------------------------------------

-- Misma firma. Solo inscripciones vigentes (como antes) y ahora solo zonas vivas de ciudades
-- vivas de la campaña: una zona dada de baja seguía abriendo sus casas (pendiente de #21).
create or replace function public.mis_zonas()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select v.zona_id
    from public.mis_campanias_vigentes() v
    join public.zona z on z.id = v.zona_id
    join public.campania_ciudad cc on cc.id = z.campania_ciudad_id
   where z.deleted_at is null
     and cc.deleted_at is null;
$$;

comment on function public.mis_zonas() is
  'Zonas vivas asignadas al usuario autenticado en sus inscripciones vigentes. Desde 0009 es la '
  'única fuente: no hay zona directa en usuario.';

-- Misma firma y mismo comportamiento que en 0008, sin la rama de usuario.zona_id.
create or replace function public.baja_zona(p_zona_id uuid, p_vista_previa boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_zona       public.zona;
  v_cc         public.campania_ciudad;
  v_asignados  jsonb;
  v_nombres    text;
  v_cambian    integer;
begin
  if auth.uid() is null then
    raise exception 'baja_zona requiere un usuario autenticado'
      using errcode = 'insufficient_privilege';
  end if;

  if not (public.tiene_rol('ADMIN') or public.tiene_rol('COORDINADOR')) then
    perform public.lanzar_motivo_mapa('SIN_PERMISO');
  end if;

  select * into v_zona from public.zona z where z.id = p_zona_id;
  if not found then
    perform public.lanzar_motivo_mapa('ZONA_INEXISTENTE');
  end if;
  select * into v_cc from public.campania_ciudad cc where cc.id = v_zona.campania_ciudad_id;
  perform public.lanzar_motivo_mapa(public.motivo_mapa_de_campania(v_cc.campania_id));

  perform public.bloquear_mapa(v_cc.id);
  select * into v_zona from public.zona z where z.id = p_zona_id for update;
  if v_zona.deleted_at is not null then
    perform public.lanzar_motivo_mapa('ZONA_INEXISTENTE');
  end if;

  -- Asignados: las inscripciones vivas con esta zona (la única fuente desde 0009).
  select jsonb_agg(jsonb_build_object('usuario_id', u.id, 'nombre', u.nombre, 'apellido', u.apellido)
                   order by u.apellido, u.nombre, u.id),
         string_agg(coalesce(nullif(btrim(concat_ws(' ', u.nombre, u.apellido)), ''), 'un colportor sin nombre'),
                    ', ' order by u.apellido, u.nombre, u.id)
    into v_asignados, v_nombres
    from public.usuario u
   where u.deleted_at is null
     and exists (select 1 from public.campania_colportor ins
                  where ins.usuario_id = u.id and ins.zona_id = p_zona_id
                    and ins.deleted_at is null);

  v_cambian := public.zona_ubicaciones_que_cambian(p_zona_id, v_cc.id, null);

  if p_vista_previa then
    return jsonb_build_object('dada_de_baja', false, 'zona', to_jsonb(v_zona) - 'xmin_w',
                              'colportores_asignados', coalesce(v_asignados, '[]'::jsonb),
                              'ubicaciones_que_cambian', v_cambian);
  end if;

  if v_asignados is not null then
    raise exception 'La zona «%» tiene colportores asignados: %. Reasignalos a otra zona antes de darla de baja.',
        v_zona.nombre, v_nombres
      using errcode = 'CZ010',
            detail = jsonb_build_object('colportores_asignados', v_asignados)::text;
  end if;

  update public.zona z set deleted_at = now() where z.id = p_zona_id
  returning * into v_zona;
  update public.zona_vertice v set deleted_at = now()
   where v.zona_id = p_zona_id and v.deleted_at is null;

  return jsonb_build_object('dada_de_baja', true, 'zona', to_jsonb(v_zona) - 'xmin_w',
                            'colportores_asignados', '[]'::jsonb,
                            'ubicaciones_que_cambian', v_cambian);
end;
$$;

-- ----------------------------------------------------------------------------
-- 4. Fuera usuario.zona_id
-- ----------------------------------------------------------------------------

drop trigger usuario_zona_servidor on public.usuario;
drop function public.tg_usuario_zona_servidor();
-- La FK usuario_zona_fk se va con la columna.
alter table public.usuario drop column zona_id;

-- ----------------------------------------------------------------------------
-- 5. CZ005 y CZ006 con el qué hacer
-- ----------------------------------------------------------------------------

-- Igual que en 0006, salvo CZ004: el mismo aviso que el mapa (0008), porque también sale
-- para una zona dada de baja, no solo para una que no existe.
create or replace function public.lanzar_motivo_zona(p_motivo text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  case p_motivo
    when 'SIN_PERMISO' then
      raise exception 'Solo el coordinador de la campaña puede asignar zonas en ella.'
        using errcode = 'insufficient_privilege';
    when 'CAMPANIA_INEXISTENTE' then
      raise exception 'La campaña no existe.' using errcode = 'CZ001';
    when 'CAMPANIA_NO_VIGENTE' then
      raise exception 'La campaña no está activa.' using errcode = 'CZ002';
    when 'NO_INSCRIPTO' then
      raise exception 'El colportor no está en esta campaña.' using errcode = 'CZ003';
    when 'ZONA_INEXISTENTE' then
      raise exception 'La zona no existe o ya se dio de baja. Recargá el mapa.' using errcode = 'CZ004';
    when 'ZONA_DE_OTRA_CIUDAD' then
      raise exception 'La zona no pertenece a la ciudad de la campaña.' using errcode = 'CZ005';
    when 'ZONA_DE_OTRA_CAMPANIA' then
      raise exception 'La zona pertenece a otra campaña.' using errcode = 'CZ006';
    else
      null;
  end case;
end;
$$;

-- Como lanzar_motivo_zona(motivo), pero con la campaña para nombrarla en CZ005 y CZ006. El
-- resto de los motivos van al de un argumento. Interna.
create function public.lanzar_motivo_zona(p_motivo text, p_campania_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_campania text := (select c.nombre from public.campania c where c.id = p_campania_id);
begin
  case p_motivo
    when 'ZONA_DE_OTRA_CAMPANIA' then
      raise exception 'La zona es de otra campaña. Elegí una zona de «%».', v_campania
        using errcode = 'CZ006';
    when 'ZONA_DE_OTRA_CIUDAD' then
      raise exception 'La ciudad de esa zona ya no está en «%». Elegí una zona de otra ciudad de la campaña o volvé a agregar la ciudad.', v_campania
        using errcode = 'CZ005';
    else
      perform public.lanzar_motivo_zona(p_motivo);
  end case;
end;
$$;

-- Igual que en 0008, con los avisos nuevos de CZ005/CZ006.
create or replace function public.asignar_zona(p_campania_id uuid, p_usuario_id uuid, p_zona_id uuid)
returns public.campania_colportor
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_filas integer;
  v_fila  public.campania_colportor;
begin
  if auth.uid() is null then
    raise exception 'asignar_zona requiere un usuario autenticado'
      using errcode = 'insufficient_privilege';
  end if;

  perform public.lanzar_motivo_zona(public.motivo_campania_del_coordinador(p_campania_id));

  perform 1 from public.campania_colportor cc
   where cc.campania_id = p_campania_id and cc.usuario_id = p_usuario_id
     and cc.deleted_at is null
     for update;

  perform 1 from public.zona z where z.id = p_zona_id for share;

  perform public.lanzar_motivo_zona(public.motivo_rechazo_zona(p_campania_id, p_usuario_id, p_zona_id),
                                    p_campania_id);

  update public.campania_colportor cc
     set zona_id = p_zona_id
   where cc.campania_id = p_campania_id and cc.usuario_id = p_usuario_id
     and cc.deleted_at is null
     and cc.zona_id is distinct from p_zona_id;
  get diagnostics v_filas = row_count;

  select * into v_fila from public.campania_colportor cc
   where cc.campania_id = p_campania_id and cc.usuario_id = p_usuario_id
     and cc.deleted_at is null;

  if v_filas = 0 and (v_fila.id is null or v_fila.zona_id is distinct from p_zona_id) then
    perform public.lanzar_motivo_zona('NO_INSCRIPTO');
  end if;

  return v_fila;
end;
$$;

-- ----------------------------------------------------------------------------
-- 6. La zona de una inscripción es de una ciudad viva de la misma campaña
-- ----------------------------------------------------------------------------

-- BEFORE INSERT/UPDATE de campania_colportor. asignar_zona() ya valida lo mismo; esto es la
-- red para cualquier otro camino. Mira cuando la zona o la campaña cambian, y cuando una
-- inscripción dada de baja se reactiva: mientras estuvo de baja nadie la contó como asignada
-- (baja_zona() solo mira las vivas), así que su zona pudo darse de baja o quedar en una ciudad
-- quitada. Una fila viva que no cambia eso no bloquea, por ejemplo, un cambio de meta_libros.
-- null («sin zona») siempre pasa.
-- Al reactivar con una zona que ya no sirve se rechaza (no se le borra la zona en silencio:
-- es un dato del colportor) y el aviso dice cómo reactivarla sin zona.
-- SECURITY DEFINER: lee zona y campania_ciudad sin depender de la RLS de quien escribe.
-- El nombre ordena DESPUÉS de campania_colportor_zona_por_rpc (los BEFORE corren por orden
-- alfabético): un UPDATE directo con JWT sigue dando 23514, no un CZ.
create function public.tg_campania_colportor_zona_valida()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reactiva      boolean := tg_op = 'UPDATE' and old.deleted_at is not null and new.deleted_at is null;
  v_zona_nombre   text;
  v_zona_viva     boolean;
  v_campania_zona uuid;
  v_ciudad_viva   boolean;
begin
  if new.zona_id is null then
    return new;
  end if;
  if tg_op = 'UPDATE' and not v_reactiva and new.zona_id is not distinct from old.zona_id
     and new.campania_id is not distinct from old.campania_id then
    return new;
  end if;

  select z.nombre, z.deleted_at is null, cc.campania_id, cc.deleted_at is null
    into v_zona_nombre, v_zona_viva, v_campania_zona, v_ciudad_viva
    from public.zona z
    join public.campania_ciudad cc on cc.id = z.campania_ciudad_id
   where z.id = new.zona_id;

  if v_reactiva and found and new.zona_id is not distinct from old.zona_id
     and v_campania_zona = new.campania_id and not (v_zona_viva and v_ciudad_viva) then
    raise exception 'La inscripción que se reactiva tiene la zona «%», que %. Reactivala sin zona (zona_id = null) y asignale otra con asignar_zona().',
        v_zona_nombre,
        case when not v_zona_viva then 'ya se dio de baja' else 'es de una ciudad que se quitó de la campaña' end
      using errcode = case when not v_zona_viva then 'CZ004' else 'CZ005' end;
  end if;

  if not found or not v_zona_viva then
    perform public.lanzar_motivo_zona('ZONA_INEXISTENTE');
  end if;
  if v_campania_zona <> new.campania_id then
    perform public.lanzar_motivo_zona('ZONA_DE_OTRA_CAMPANIA', new.campania_id);
  end if;
  if not v_ciudad_viva then
    perform public.lanzar_motivo_zona('ZONA_DE_OTRA_CIUDAD', new.campania_id);
  end if;
  return new;
end;
$$;

create trigger campania_colportor_zona_valida
  before insert or update on public.campania_colportor
  for each row execute function public.tg_campania_colportor_zona_valida();

-- ----------------------------------------------------------------------------
-- 7. Privilegios
-- ----------------------------------------------------------------------------

-- `authenticated` también: en una base creada desde cero los default privileges de la imagen
-- le dan EXECUTE sobre cada función nueva de public (ver 0008).
revoke all on function
  public.lanzar_motivo_zona(text, uuid),
  public.tg_campania_colportor_zona_valida()
  from public, anon, authenticated;
grant execute on function public.lanzar_motivo_zona(text, uuid) to service_role;
