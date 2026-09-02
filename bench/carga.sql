-- Volumen realista para medir: 150 colportores, una temporada de trabajo.
--
-- RP-01 habla de 80–200 usuarios; RR-02 de lotes de 100 registros en menos de
-- 30 s. Estos números son el techo de esa horquilla.

\timing off

insert into jornada (id, pk_usuario, inicio, km_recorridos, sync_version, updated_at)
select
  ('018f2c4e-6b7d-7a11-9f3c-' || lpad(g::text, 12, '0'))::uuid,
  ('11111111-1111-4111-8111-' || lpad((g % 150)::text, 12, '0'))::uuid,
  timestamptz '2026-06-01' + (g % 180) * interval '1 day',
  (g % 90)::numeric,
  1,
  timestamptz '2026-06-01' + g * interval '31 seconds'
from generate_series(1, 120000) g;

insert into ubicacion (id, pk_usuario, lat, lon, estado, sync_version, updated_at)
select
  ('018f2c4e-6b7d-7a22-9f3c-' || lpad(g::text, 12, '0'))::uuid,
  ('11111111-1111-4111-8111-' || lpad((g % 150)::text, 12, '0'))::uuid,
  -27.3 + (g % 1000) / 10000.0,
  -55.9 + (g % 1000) / 10000.0,
  case g % 3 when 0 then 'NO_VISITADA' when 1 then 'VENDIDA' else 'AUSENTE' end,
  1,
  timestamptz '2026-06-01' + g * interval '17 seconds'
from generate_series(1, 300000) g;

analyze jornada;
analyze ubicacion;

select 'jornada' as tabla, count(*) from jornada
union all select 'ubicacion', count(*) from ubicacion;
