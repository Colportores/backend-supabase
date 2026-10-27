import { assertEquals, assertRejects } from "@std/assert";

import { CAMPANIA, colportorQueTrabaja, mundoVacio, rpcDe, uuid } from "./apoyo.ts";
import {
  elegirCampania,
  ErrorDeLaBase,
  ID_SIN_ZONA,
  leerDatos,
  NOMBRE_SIN_ZONA,
  RespuestaInesperada,
  sinDatosDesde,
  TOPE_FILAS,
} from "./datos.ts";

const HOY = "2026-10-21";

Deno.test("datos · lee con p_agrupar = dia desde el inicio de la campaña hasta hoy, sin filtros", async () => {
  const mundo = mundoVacio({
    colportores: [colportorQueTrabaja(1, "Ana", "Pérez", "2026-10-05", "2026-10-20")],
    departamentos: { [uuid(10)]: "Rivera" },
  });
  const { llamar, llamadas } = rpcDe(mundo);
  const datos = await leerDatos(llamar, null, HOY);

  const horas = llamadas.find((l) => l.nombre === "horas_por_ciudad_y_colportor");
  assertEquals(horas?.argumentos, {
    p_campania_id: CAMPANIA,
    p_desde: "2026-10-05",
    p_hasta: HOY,
    p_agrupar: "dia",
    p_ciudad_id: null,
    p_colportor_ids: null,
  });
  assertEquals(datos?.ciudades.map((c) => [c.nombre, c.departamento]), [["Rivera", "Rivera"]]);
  assertEquals(datos?.ciudades[0].colportores[0].nombre, "Ana Pérez");
  assertEquals(datos?.ciudades[0].colportores[0].horasPorDia["2026-10-06"], 6);
  assertEquals(datos?.inicioCampania, "2026-10-05");
  assertEquals(datos?.hoy, HOY);
});

Deno.test("datos · el monto llega en centavos y se pasa a $U", async () => {
  const c = colportorQueTrabaja(1, "Ana", "Pérez", "2026-10-06", "2026-10-06");
  c.ventas = { "2026-10-06": [3, 8, 1_234_550] };
  const { llamar } = rpcDe(mundoVacio({ colportores: [c] }));
  const datos = await leerDatos(llamar, null, HOY);
  assertEquals(datos?.ciudades[0].colportores[0].ventasPorDia["2026-10-06"], {
    ventas: 3,
    presentaciones: 8,
    monto: 12345.5,
  });
});

Deno.test("datos · un día trabajado sin ventas es de 0 ventas, no «sin datos»", async () => {
  const c = colportorQueTrabaja(1, "Ana", "Pérez", "2026-10-06", "2026-10-06");
  c.ventas = {};
  const { llamar } = rpcDe(mundoVacio({ colportores: [c] }));
  const datos = await leerDatos(llamar, null, HOY);
  assertEquals(datos?.ciudades[0].colportores[0].ventasPorDia["2026-10-06"], {
    ventas: 0,
    presentaciones: 0,
    monto: 0,
  });
});

Deno.test("datos · una fila en cero de un día sin jornada (existe por el período anterior) no es un dato", async () => {
  const c = colportorQueTrabaja(1, "Ana", "Pérez", "2026-10-06", "2026-10-06");
  c.ventas = { "2026-10-07": [0, 0, 0] };
  const { llamar } = rpcDe(mundoVacio({ colportores: [c] }));
  const datos = await leerDatos(llamar, null, HOY);
  const dias = datos?.ciudades[0].colportores[0].ventasPorDia ?? {};
  assertEquals(Object.keys(dias), ["2026-10-06"]);
});

Deno.test("datos · vender sin tener jornada cerrada cuenta como dato", async () => {
  const c = colportorQueTrabaja(1, "Ana", "Pérez", "2026-10-06", "2026-10-06");
  c.ventas = { "2026-10-07": [1, 2, 50_000] };
  const { llamar } = rpcDe(mundoVacio({ colportores: [c] }));
  const datos = await leerDatos(llamar, null, HOY);
  assertEquals(datos?.ciudades[0].colportores[0].ventasPorDia["2026-10-07"], {
    ventas: 1,
    presentaciones: 2,
    monto: 500,
  });
});

Deno.test("datos · quienes no tienen zona van una sola vez, al final, en «Sin zona asignada»", async () => {
  const sinZona = colportorQueTrabaja(2, "Luis", "Gómez", "2026-10-06", "2026-10-06", {
    ciudadId: null,
    ciudadNombre: null,
  });
  const { llamar } = rpcDe(mundoVacio({
    colportores: [sinZona, colportorQueTrabaja(1, "Ana", "Pérez", "2026-10-06", "2026-10-06")],
  }));
  const datos = await leerDatos(llamar, null, HOY);
  assertEquals(datos?.ciudades.map((c) => c.id), [uuid(10), ID_SIN_ZONA]);
  assertEquals(datos?.ciudades[1].nombre, NOMBRE_SIN_ZONA);
  assertEquals(datos?.ciudades[1].departamento, null);
  assertEquals(datos?.ciudades[1].colportores.length, 1);
});

Deno.test("datos · quien está inscripto y todavía no tiene horas figura igual, sin datos", async () => {
  const nuevo = colportorQueTrabaja(3, "Marta", "Díaz", "2026-10-06", "2026-10-06", {
    horas: {},
    ventas: {},
    inscripto: true,
  });
  const { llamar } = rpcDe(mundoVacio({ colportores: [nuevo] }));
  const datos = await leerDatos(llamar, null, HOY);
  const c = datos?.ciudades[0].colportores[0];
  assertEquals(c?.nombre, "Marta Díaz");
  assertEquals(c?.horasPorDia, {});
  assertEquals(c?.sinDatosDesde, null);
});

Deno.test("datos · colportores ordenados por apellido y nombre; ciudades por nombre", async () => {
  const { llamar } = rpcDe(mundoVacio({
    colportores: [
      colportorQueTrabaja(1, "Zoe", "Álvarez", "2026-10-06", "2026-10-06"),
      colportorQueTrabaja(2, "Ana", "Zapata", "2026-10-06", "2026-10-06"),
      colportorQueTrabaja(3, "Beto", "Álvarez", "2026-10-06", "2026-10-06"),
      colportorQueTrabaja(4, "Carla", "Mora", "2026-10-06", "2026-10-06", {
        ciudadId: uuid(11),
        ciudadNombre: "Artigas",
      }),
    ],
  }));
  const datos = await leerDatos(llamar, null, HOY);
  assertEquals(datos?.ciudades.map((c) => c.nombre), ["Artigas", "Rivera"]);
  assertEquals(datos?.ciudades[1].colportores.map((c) => c.nombre), ["Beto Álvarez", "Zoe Álvarez", "Ana Zapata"]);
});

Deno.test("datos · un colportor sin nombre ni apellido sale con un título, no vacío", async () => {
  const sinNombre = colportorQueTrabaja(1, "", "", "2026-10-06", "2026-10-06");
  const { llamar } = rpcDe(mundoVacio({ colportores: [sinNombre] }));
  const datos = await leerDatos(llamar, null, HOY);
  assertEquals(datos?.ciudades[0].colportores[0].nombre, "Colportor sin nombre");
});

Deno.test("datos · «sin datos desde»: dos días de trabajo seguidos sin horas, sin contar hoy ni domingos", () => {
  const horas = { "2026-10-13": 5, "2026-10-14": 5 };
  // Hoy es jueves 15: el miércoles 14 tiene horas, nada que avisar.
  assertEquals(sinDatosDesde(horas, "2026-10-15", "2026-10-15"), null);
  // Hoy es sábado 17: faltan el jueves 15 y el viernes 16 → desde el 14.
  assertEquals(sinDatosDesde(horas, "2026-10-17", "2026-10-17"), "2026-10-14");
  // Hoy es viernes 16: solo falta el jueves 15 (y hoy no cuenta).
  assertEquals(sinDatosDesde(horas, "2026-10-16", "2026-10-16"), null);
  // Quien nunca tuvo horas no tiene «desde».
  assertEquals(sinDatosDesde({}, "2026-10-17", "2026-10-17"), null);
  // El domingo no cuenta como día sin horas: viernes 16 con horas, sábado sin, domingo 18 sin → solo el sábado.
  assertEquals(sinDatosDesde({ "2026-10-16": 5 }, "2026-10-19", "2026-10-19"), null);
});

Deno.test("datos · una respuesta cortada por el tope de filas se parte hasta traer todo", async () => {
  // 300 colportores × 6 días = 1800 filas; PostgREST corta en 1000: sin partir se perderían los días nuevos.
  const colportores = Array.from(
    { length: 300 },
    (_, i) => colportorQueTrabaja(i, `Nombre${i}`, `Apellido${String(i).padStart(3, "0")}`, "2026-10-05", "2026-10-10"),
  );
  const { llamar, llamadas } = rpcDe(mundoVacio({ colportores }));
  const datos = await leerDatos(llamar, null, "2026-10-12");
  const todos = datos?.ciudades.flatMap((c) => c.colportores) ?? [];
  assertEquals(todos.length, 300);
  for (const c of todos) assertEquals(Object.keys(c.horasPorDia).length, 6);
  const pedidos = llamadas.filter((l) => l.nombre === "horas_por_ciudad_y_colportor");
  assertEquals(pedidos.length > 1, true);
  // Los tramos no se pisan: si un día llegara dos veces, sus 6 horas saldrían como 12.
  for (const c of todos) assertEquals(Object.values(c.horasPorDia), [6, 6, 6, 6, 6, 6]);
});

Deno.test("datos · un solo día con el tope de filas no se puede partir: error, nunca datos a medias", async () => {
  const colportores = Array.from(
    { length: TOPE_FILAS },
    (_, i) => colportorQueTrabaja(i, `N${i}`, `A${i}`, "2026-10-06", "2026-10-06"),
  );
  const { llamar } = rpcDe(mundoVacio({
    colportores,
    campanias: [{ id: CAMPANIA, nombre: "C", fecha_inicio: "2026-10-06", fecha_fin: "2026-10-06" }],
  }));
  await assertRejects(() => leerDatos(llamar, null, "2026-10-06"), RespuestaInesperada, "puede estar cortada");
});

Deno.test("datos · un rango de más de 366 días se parte antes de pedirlo", async () => {
  const mundo = mundoVacio({
    campanias: [{ id: CAMPANIA, nombre: "C", fecha_inicio: "2025-01-06", fecha_fin: null }],
    colportores: [colportorQueTrabaja(1, "Ana", "Pérez", "2025-01-06", "2026-10-20")],
  });
  const { llamar, llamadas } = rpcDe(mundo);
  const datos = await leerDatos(llamar, null, HOY);
  const pedidos = llamadas.filter((l) => l.nombre === "horas_por_ciudad_y_colportor");
  assertEquals(pedidos.length >= 2, true);
  // Una campaña de casi dos años: el día 1 y el último llegan (y no se pidió más de 366 días de una vez).
  const dias = datos?.ciudades[0].colportores[0].horasPorDia ?? {};
  assertEquals("2025-01-06" in dias && "2026-10-20" in dias, true);
});

Deno.test("datos · sin campaña, con una que no empezó, o que se dio de baja mientras se leía: null", async () => {
  assertEquals(await leerDatos(rpcDe(mundoVacio({ campanias: [] })).llamar, null, HOY), null);
  assertEquals(
    await leerDatos(
      rpcDe(mundoVacio({ campanias: [{ id: CAMPANIA, nombre: "C", fecha_inicio: "2026-11-02", fecha_fin: null }] }))
        .llamar,
      null,
      HOY,
    ),
    null,
  );
  for (const codigo of ["CZ001", "CZ011"]) {
    const { llamar } = rpcDe(
      mundoVacio({
        colportores: [colportorQueTrabaja(1, "A", "B", "2026-10-06", "2026-10-06")],
        fallas: { horas_por_ciudad_y_colportor: codigo },
      }),
    );
    assertEquals(await leerDatos(llamar, null, HOY), null);
  }
});

Deno.test("datos · una campaña terminada no deja leer los departamentos (CZ011): las ciudades quedan sin departamento", async () => {
  const { llamar } = rpcDe(mundoVacio({
    colportores: [colportorQueTrabaja(1, "Ana", "Pérez", "2026-10-06", "2026-10-06")],
    fallas: { ciudades_de_campania: "CZ011" },
  }));
  const datos = await leerDatos(llamar, null, HOY);
  assertEquals(datos?.ciudades[0].departamento, null);
});

Deno.test("datos · una falla de permiso o de la base NO se toma por «sin datos»: sale como error", async () => {
  for (
    const rpc of [
      "campanias_del_coordinador",
      "horas_por_ciudad_y_colportor",
      "ventas_por_ciudad_y_colportor",
      "zonas_por_colportor",
    ]
  ) {
    const { llamar } = rpcDe(
      mundoVacio({
        colportores: [colportorQueTrabaja(1, "A", "B", "2026-10-06", "2026-10-06")],
        fallas: { [rpc]: "42501" },
      }),
    );
    const error = await assertRejects(() => leerDatos(llamar, null, HOY), ErrorDeLaBase);
    assertEquals(error.codigo, "42501");
  }
});

Deno.test("datos · la campaña pedida solo vale si figura en la lista de quien llama; si no, la primera", async () => {
  const otra = "01920000-0000-7000-8000-0000000000ff";
  const mundo = mundoVacio({
    campanias: [
      { id: CAMPANIA, nombre: "Primera", fecha_inicio: "2026-10-05", fecha_fin: null },
      { id: otra, nombre: "Segunda", fecha_inicio: "2026-11-02", fecha_fin: null },
    ],
  });
  assertEquals((await elegirCampania(rpcDe(mundo).llamar, otra))?.nombre, "Segunda");
  assertEquals((await elegirCampania(rpcDe(mundo).llamar, "01920000-0000-7000-8000-00000000aaaa"))?.nombre, "Primera");
  assertEquals((await elegirCampania(rpcDe(mundo).llamar, null))?.nombre, "Primera");
});

Deno.test("datos · una respuesta que no tiene la forma del contrato es un error, no datos a medias", async () => {
  const llamar = (nombre: string) => {
    if (nombre === "campanias_del_coordinador") return Promise.resolve({ no: "una lista" });
    return Promise.resolve([]);
  };
  await assertRejects(() => leerDatos(llamar, null, HOY), RespuestaInesperada, "no es una lista de filas");
  const sinFecha = () => Promise.resolve([{ id: CAMPANIA, nombre: "C", fecha_inicio: "ayer", fecha_fin: null }]);
  await assertRejects(() => leerDatos(sinFecha, null, HOY), RespuestaInesperada, "no es un día");
});

Deno.test("datos · lo que se lee no incluye nada de clientes: solo los campos del contrato de totales", async () => {
  const c = colportorQueTrabaja(1, "Ana", "Pérez", "2026-10-06", "2026-10-06");
  const { llamar, llamadas } = rpcDe(mundoVacio({ colportores: [c] }));
  const datos = await leerDatos(llamar, null, HOY);
  const permitidas = new Set([
    "campanias_del_coordinador",
    "horas_por_ciudad_y_colportor",
    "ventas_por_ciudad_y_colportor",
    "zonas_por_colportor",
    "ciudades_de_campania",
  ]);
  for (const l of llamadas) assertEquals(permitidas.has(l.nombre), true, l.nombre);
  const colportor = datos?.ciudades[0].colportores[0];
  assertEquals(Object.keys(colportor ?? {}).sort(), ["horasPorDia", "id", "nombre", "sinDatosDesde", "ventasPorDia"]);
});

Deno.test("datos · una fila de horas con jornadas = 0 (existe por el período anterior) no cuenta como día con datos ni como 0 horas", async () => {
  const c = colportorQueTrabaja(1, "Ana", "Pérez", "2026-10-06", "2026-10-06");
  const { llamar } = rpcDe(mundoVacio({ colportores: [c] }));
  const conFilaEnCero: typeof llamar = async (nombre, argumentos) => {
    const filas = await llamar(nombre, argumentos);
    if (nombre !== "horas_por_ciudad_y_colportor") return filas;
    const base = (filas as Record<string, unknown>[])[0];
    return [...(filas as unknown[]), {
      ...base,
      periodo_inicio: "2026-10-07",
      periodo_fin: "2026-10-07",
      horas: 0,
      jornadas: 0,
    }];
  };
  const datos = await leerDatos(conFilaEnCero, null, HOY);
  assertEquals(Object.keys(datos?.ciudades[0].colportores[0].horasPorDia ?? {}), ["2026-10-06"]);
});
