-- ============================================================================
-- Corrige, una sola vez, la fecha de alta de las 13 inscripciones de la demo generada (demo-datos.sql)
--
-- Por qué: la primera carga dejó `campania_colportor.created_at` y el primer tramo del historial de zonas
-- (`campania_colportor_zona_historial.desde`) con la hora de la carga (04/11), posterior a toda la actividad de la demo
-- (13/07 a 03/11). Inicio y Reportes (`tablero_de_inicio`, `horas_por_ciudad_y_colportor`, `ventas_por_ciudad_y_colportor`,
-- 0106) solo cuentan lo que pasó con la inscripción vigente y en la zona de ese día, así que la demo salía en cero.
-- El generador ya carga estas fechas bien; esto arregla la base donde se cargó antes (ohdsavwpasfpapbyutrv).
-- Autorizado por Cristian el 11/11 (P1 de pendientes/backend-supabase-251-impl-261111-0832.md).
--
-- Qué hace (26 filas como mucho, todas de la demo):
--   · `campania_colportor.created_at` = primer día de cada inscripción (00:00 de Montevideo), solo si hoy es posterior.
--     `tg_auditoria_update` (0001) congela created_at en todo UPDATE: el trigger `campania_colportor_auditoria_update`
--     se desactiva y se vuelve a activar DENTRO del mismo DO (es transaccional: si algo falla, queda como estaba).
--     Sin ese trigger tampoco suben updated_at ni sync_version: los usuarios de la demo no tienen teléfono.
--   · `campania_colportor_zona_historial.desde` del PRIMER tramo de cada una = esa misma fecha, solo si hoy es posterior.
-- Solo los 13 ids fijos de la demo (5eed0000-0000-7000-800b-…01..0d). Nunca DELETE ni cambios de esquema permanentes.
-- Idempotente: la segunda corrida no encuentra nada que corregir.
--
-- Cómo se corre: scripts/db-seed-demo.sh [--remoto] --fechas (vista previa: hace todo, cuenta y deshace) y, para
-- aplicarlo, --fechas --aplicar. Para aplicarlo a mano: cambiar `v_aplicar boolean := false;` por `true` abajo.
-- ============================================================================

create temp table if not exists fechas_demo_resumen (orden serial, que text, filas integer);
truncate fechas_demo_resumen;

do $fechas$
declare
  v_aplicar boolean := false;  -- fechas:aplicar (el script cambia este false por true con --aplicar)
  v_inscr   integer := 0;
  v_tramos  integer := 0;
begin
  -- Los tests pueden activarlo con la marca de transacción `fechas.aplicar`.
  v_aplicar := v_aplicar or coalesce(current_setting('fechas.aplicar', true), '') = 'si';

  create temp table if not exists fechas_demo_alta (id uuid primary key, alta timestamptz not null);
  truncate fechas_demo_alta;
  insert into fechas_demo_alta (id, alta)
  select ('5eed0000-0000-7000-800b-' || lpad(to_hex(v.no), 12, '0'))::uuid as id,
         v.d0::timestamp at time zone 'America/Montevideo'
    from (values (1, date '2026-09-14'), (2, date '2026-09-14'), (3, date '2026-09-14'), (4, date '2026-09-14'),
                 (5, date '2026-09-28'), (6, date '2026-09-14'), (7, date '2026-09-14'), (8, date '2026-09-21'),
                 (9, date '2026-09-14'), (10, date '2026-10-05'), (11, date '2026-07-13'), (12, date '2026-07-13'),
                 (13, date '2026-07-20')) v(no, d0);

  begin
    execute 'alter table public.campania_colportor disable trigger campania_colportor_auditoria_update';
    update public.campania_colportor cc
       set created_at = f.alta
      from fechas_demo_alta f
     where cc.id = f.id
       and cc.created_at > f.alta;
    get diagnostics v_inscr = row_count;
    execute 'alter table public.campania_colportor enable trigger campania_colportor_auditoria_update';

    update public.campania_colportor_zona_historial h
       set desde = f.alta
      from fechas_demo_alta f
     where h.campania_colportor_id = f.id
       and h.deleted_at is null
       and h.desde > f.alta
       and not exists (select 1 from public.campania_colportor_zona_historial h2
                        where h2.campania_colportor_id = h.campania_colportor_id and h2.desde < h.desde);
    get diagnostics v_tramos = row_count;

    if v_inscr > 13 or v_tramos > 13 then
      raise exception 'Corrección frenada: tocaría % inscripciones y % tramos (máximo 13 y 13).', v_inscr, v_tramos;
    end if;

    if not v_aplicar then
      raise exception 'vista previa' using errcode = 'FD001';
    end if;
  exception when sqlstate 'FD001' then
    null;  -- vista previa: se deshace el bloque (también el disable/enable del trigger)
  end;

  insert into fechas_demo_resumen (que, filas)
  values (case when v_aplicar then 'APLICADO' else 'VISTA PREVIA (no se cambió nada)' end, 0),
         ('campania_colportor.created_at', v_inscr),
         ('campania_colportor_zona_historial.desde (primer tramo)', v_tramos);
end
$fechas$;

select que, filas from fechas_demo_resumen order by orden;
