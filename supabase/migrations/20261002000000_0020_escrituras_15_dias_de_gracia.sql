-- ============================================================================
-- 0020 · Lo que sube tarde: las escrituras se aceptan hasta 15 días después de que la campaña
--        terminó (backend-supabase#32, decisión de Cristian del 02/10)
--
-- Decisión de Cristian del 02/10 (backend-supabase#32, comentario 5951937291, y #36): «Caso: un
-- colportor vende sin señal el último día de la campaña y sincroniza al día siguiente (o a las
-- 21:30, porque la base corta en UTC). Las escrituras de un colportor que estuvo inscripto en la
-- campaña se aceptan hasta 15 días después de que la campaña terminó. Pasado eso, se rechazan
-- como hoy.»
--
-- ## Qué escrituras dependen de la campaña
--
-- Las que pasan por mis_ciudades_de_campania() (0011): corregir una ubicación ajena, y cargar o
-- corregir espacios y estados (house_status) en ella (puedo_escribir_en_ubicacion(), y desde 0018
-- también la corrección y la baja del espacio propio). Registrar una casa nueva, y la persona, la
-- visita y la venta, no miran la campaña (son suyas por created_by o colportor_id). Caso del
-- último día: el depto nuevo de una casa ajena volvía 42501 al día siguiente, y colgando de él la
-- persona, la visita y la venta (23503).
--
-- ## La regla
--
-- mis_ciudades_de_campania() pasa a salir de mis_campanias_para_escribir(): las inscripciones
-- vivas del usuario (como hoy: inscripción y cuenta sin dar de baja, campaña viva y ya empezada)
-- en campañas que no terminaron o que terminaron hace 15 días o menos. El día se cuenta en la
-- hora del proyecto, America/Montevideo (docs/08-conceptos-transversales.md, §8.6), no en UTC:
-- con fecha_fin = D, el día D + 15 se acepta hasta las 23:59 de Montevideo (02:59 UTC del día
-- siguiente) y el D + 16 no. Lo decide escritura_dentro_de_plazo(fecha_fin, ahora), pura para
-- poder probar la hora.
--   · El comienzo no cambia: la campaña ya empezó (fecha_inicio <= current_date, como
--     campania_vigente() de 0005).
--   · mis_campanias_vigentes() no cambia: sigue decidiendo el estado de la cuenta, la zona y la
--     inscripción. La gracia es solo para escribir.
--   · La lectura no cambia: cuando la campaña termina, la RLS de lectura deja de mostrarle las
--     casas ajenas de esa ciudad (mis_ciudades_de_trabajo(), 0011 y 0013). Lo nuevo (el depto, el
--     estado nuevo, la persona, la visita, la venta) entra; la corrección de una fila ajena que ya
--     no ve (un estado o una casa de otro) sigue volviendo FILA_INEXISTENTE. Si eso también tiene
--     que entrar durante los 15 días, es una decisión aparte (se anotó en el PR).
--
-- ## Para otros repos
--
--   · front-colportores-mobile y motor (#178): durante los 15 días después del fin de una campaña
--     el push acepta lo cargado en ella; después, 42501 como hoy.
--
-- Datos: ninguno; solo funciones.
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- Si una campaña con esa fecha de fin todavía admite escrituras en ese momento: no terminó, o
-- terminó hace 15 días o menos, contados en la hora de America/Montevideo. Pura (sin datos).
create function public.escritura_dentro_de_plazo(p_fecha_fin date, p_ahora timestamptz default now())
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_fecha_fin is null
      or p_fecha_fin + 15 >= (p_ahora at time zone 'America/Montevideo')::date;
$$;

comment on function public.escritura_dentro_de_plazo(date, timestamptz) is
  'Si una campaña que termina en p_fecha_fin admite escrituras en p_ahora: no terminó, o terminó '
  'hace 15 días o menos, en la hora de America/Montevideo (0020, decisión del 02/10).';

-- Las inscripciones del usuario autenticado en las que puede escribir: vivas, de una campaña viva
-- que ya empezó y que no terminó o terminó hace 15 días o menos. Interna: la llama
-- mis_ciudades_de_campania(), que es SECURITY DEFINER.
create function public.mis_campanias_para_escribir()
returns table (campania_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select cc.campania_id
    from public.campania_colportor cc
    join public.usuario u on u.id = cc.usuario_id
    join public.campania c on c.id = cc.campania_id
   where cc.usuario_id = auth.uid()
     and cc.deleted_at is null
     and u.deleted_at is null
     and c.deleted_at is null
     and c.fecha_inicio <= current_date
     and public.escritura_dentro_de_plazo(c.fecha_fin);
$$;

comment on function public.mis_campanias_para_escribir() is
  'Campañas del usuario autenticado en las que puede escribir: inscripción viva, ya empezada, y '
  'sin terminar o terminada hace 15 días o menos (0020). Interna.';

-- Misma firma y mismo cuerpo que en 0011, salvo de dónde salen las campañas.
create or replace function public.mis_ciudades_de_campania()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select distinct cc.ciudad_id
    from public.mis_campanias_para_escribir() v
    join public.campania_ciudad cc on cc.campania_id = v.campania_id
   where cc.deleted_at is null;
$$;

comment on function public.mis_ciudades_de_campania() is
  'Ciudades vivas de las campañas del usuario autenticado en las que puede escribir: vigentes o '
  'terminadas hace 15 días o menos (0020), tenga zona o no (decisión del 30/09 sobre S55: la zona '
  'acota solo la lectura). Decide dónde corrige ubicaciones y carga espacios y estados un '
  'colportor (RLS de escritura).';

-- ----------------------------------------------------------------------------
-- Privilegios
-- ----------------------------------------------------------------------------

-- `authenticated` también en el revoke: en una base creada desde cero los default privileges de
-- la imagen le dan EXECUTE sobre cada función nueva de public (ver 0008). Las dos son internas:
-- las llaman funciones SECURITY DEFINER. mis_ciudades_de_campania() conserva sus privilegios.
revoke all on function public.escritura_dentro_de_plazo(date, timestamptz) from public, anon, authenticated;
revoke all on function public.mis_campanias_para_escribir() from public, anon, authenticated;
