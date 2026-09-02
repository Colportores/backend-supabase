-- Delta pull (§6.2 del formato de cable).
--
-- El watermark es (updated_at, id) **por entidad**, no un reloj global. Con un
-- watermark único, si `precio_por_zona` avanza hasta las 15:44 y después
-- aparece una `ubicacion` con updated_at 15:43 —dos transacciones que
-- commitearon en distinto orden del que tomaron el timestamp— esa fila se
-- saltea para siempre. El par (updated_at, id) desempata y el por-entidad evita
-- que una colección arrastre a la otra.

create function sync.pull(
  p_usuario   uuid,
  p_entidades text[],
  p_watermark jsonb default '{}'::jsonb,
  p_limite    int default 500
) returns jsonb language plpgsql as $$
declare
  v_entidad   text;
  v_tabla     regclass;
  v_desde     jsonb;
  v_filas     jsonb;
  v_rows      jsonb := '{}'::jsonb;
  v_nuevo     jsonb := coalesce(p_watermark, '{}'::jsonb);
  v_hay_mas   boolean := false;
  v_ultima    jsonb;
begin
  foreach v_entidad in array p_entidades loop
    select e.tabla into v_tabla from sync.entidad e where e.nombre = v_entidad;
    -- Una entidad que el cliente pide y el servidor no conoce se ignora: un
    -- cliente más nuevo que el backend no puede tumbar la sync de los demás.
    continue when v_tabla is null;

    v_desde := coalesce(p_watermark -> v_entidad,
                        jsonb_build_object('ts', '-infinity', 'id', '00000000-0000-0000-0000-000000000000'));

    -- Se pide una fila de más para saber si hay más sin contar la tabla entera.
    execute format($q$
      select coalesce(jsonb_agg(j order by ts, id), '[]'::jsonb)
      from (
        select %s as j, t.updated_at as ts, t.id as id
        from %s t
        where t.pk_usuario = $1
          and (t.updated_at, t.id) > ($2::timestamptz, $3::uuid)
        order by t.updated_at, t.id
        limit $4 + 1
      ) s
    $q$, sync.expresion_json(v_tabla), v_tabla)
    into v_filas
    using p_usuario, (v_desde ->> 'ts'), (v_desde ->> 'id')::uuid, p_limite;

    continue when jsonb_array_length(v_filas) = 0;

    if jsonb_array_length(v_filas) > p_limite then
      v_hay_mas := true;
      v_filas := (select jsonb_agg(f) from (
        select f from jsonb_array_elements(v_filas) f limit p_limite
      ) s);
    end if;

    -- Una entidad ausente de `rows` significa "sin cambios": el cliente no
    -- borra nada por ausencia, así que solo se incluyen las que traen algo.
    v_rows := v_rows || jsonb_build_object(v_entidad, v_filas);

    v_ultima := v_filas -> (jsonb_array_length(v_filas) - 1);
    v_nuevo := v_nuevo || jsonb_build_object(v_entidad, jsonb_build_object(
      'ts', v_ultima ->> 'updated_at',
      'id', v_ultima ->> 'id'
    ));
  end loop;

  return jsonb_build_object(
    'server_time', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'watermark', v_nuevo,
    'has_more', v_hay_mas,
    'rows', v_rows
  );
end;
$$;
