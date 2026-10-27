import type { Granularidad } from "./calculo.ts";
import { ErrorDeLaBase, leerDatos, type LlamarRpc, RespuestaInesperada } from "./datos.ts";
import { hoyEnMontevideo } from "./fechas.ts";
import { crearInformePdf } from "./pdf.ts";
import { type Ambito, armarReporte } from "./reporte.ts";

/**
 * Edge Function `informe-reportes` (backend-supabase#144, HU-REP-005, decisión de Cristian del 23/10, «PDF informe»):
 * arma el «Informe PDF» de la vista 32 (Reportes) y lo devuelve para bajar. Lee las mismas RPC que la pantalla con la
 * sesión de la coordinadora (manda la RLS: no usa la clave de servicio), y arma la marca, los filtros aplicados y las
 * cifras. Nunca lleva datos de clientes. Contrato completo en `README.md`.
 */

export interface Dependencias {
  fetch: typeof fetch;
  /** Dirección de la API del proyecto (`SUPABASE_URL`). */
  urlDeLaApi: string;
  /** La clave pública (`SUPABASE_ANON_KEY`): identifica al proyecto, no da ningún permiso. */
  clavePublica: string;
  ahora: () => Date;
}

export interface PedidoDeInforme {
  campaniaId: string | null;
  ambito: Ambito;
  granularidad: Granularidad;
}

/** Cuánto puede pesar el pedido: el cuerpo real mide menos de 300 bytes. */
const MAXIMO_DEL_CUERPO = 4096;
const LARGO_MAXIMO_DE_UN_ID = 64;
const LARGO_MAXIMO_DEL_DEPARTAMENTO = 80;

const CABECERAS_CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Expose-Headers": "Content-Disposition",
  "Access-Control-Max-Age": "86400",
};

/** Los textos son para la persona (el panel los muestra tal cual): qué pasó y qué hacer. */
const MENSAJES = {
  metodo: "Este servicio solo acepta pedidos POST.",
  pedido_invalido: "El pedido del informe no es válido. Volvé a abrir Reportes e intentá de nuevo.",
  pedido_muy_grande: "El pedido del informe es demasiado grande. Volvé a abrir Reportes e intentá de nuevo.",
  sin_sesion: "Tu sesión terminó. Iniciá sesión de nuevo para descargar el informe PDF.",
  sin_permiso: "No tenés permiso para descargar el informe de esta campaña.",
  sin_campania: "No tenés una campaña en curso para armar el informe.",
  sin_datos: "No hay colportores para exportar en este reporte.",
  no_se_pudo_leer: "No pudimos leer los reportes. Esperá unos minutos y volvé a intentar.",
  no_se_pudo_armar: "No pudimos armar el informe PDF. Volvé a intentar en unos minutos.",
} as const;

type CodigoDeError = keyof typeof MENSAJES;

const ESTADO_HTTP: Record<CodigoDeError, number> = {
  metodo: 405,
  pedido_invalido: 400,
  pedido_muy_grande: 413,
  sin_sesion: 401,
  sin_permiso: 403,
  sin_campania: 404,
  sin_datos: 422,
  no_se_pudo_leer: 502,
  no_se_pudo_armar: 500,
};

function errorJson(codigo: CodigoDeError): Response {
  return new Response(JSON.stringify({ error: { codigo, mensaje: MENSAJES[codigo] } }), {
    status: ESTADO_HTTP[codigo],
    headers: { ...CABECERAS_CORS, "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
  });
}

function esObjeto(valor: unknown): valor is Record<string, unknown> {
  return typeof valor === "object" && valor !== null && !Array.isArray(valor);
}

function texto(valor: unknown, largoMaximo: number): string | null {
  return typeof valor === "string" && valor.trim() !== "" && valor.length <= largoMaximo ? valor : null;
}

/** El pedido tal como lo manda el panel (`Ambito` y `Granularidad` de la vista 32), o `null` si no es válido. */
export function leerPedido(cuerpo: unknown): PedidoDeInforme | null {
  if (!esObjeto(cuerpo)) return null;

  let campaniaId: string | null = null;
  if (cuerpo.campaniaId !== undefined && cuerpo.campaniaId !== null) {
    campaniaId = texto(cuerpo.campaniaId, LARGO_MAXIMO_DE_UN_ID);
    if (campaniaId === null) return null;
  }

  const granularidad = cuerpo.granularidad;
  if (granularidad !== "dia" && granularidad !== "semana" && granularidad !== "mes") return null;

  const a = cuerpo.ambito;
  if (!esObjeto(a)) return null;
  let ambito: Ambito;
  if (a.tipo === "todas") {
    ambito = { tipo: "todas" };
  } else if (a.tipo === "departamento") {
    const departamento = texto(a.departamento, LARGO_MAXIMO_DEL_DEPARTAMENTO);
    if (departamento === null) return null;
    ambito = { tipo: "departamento", departamento };
  } else if (a.tipo === "ciudad") {
    const ciudadId = texto(a.ciudadId, LARGO_MAXIMO_DE_UN_ID);
    if (ciudadId === null) return null;
    ambito = { tipo: "ciudad", ciudadId };
  } else if (a.tipo === "colportor") {
    const colportorId = texto(a.colportorId, LARGO_MAXIMO_DE_UN_ID);
    if (colportorId === null) return null;
    ambito = { tipo: "colportor", colportorId };
  } else {
    return null;
  }
  return { campaniaId, ambito, granularidad };
}

/**
 * Nombre del archivo: lo que se está viendo y el día, sin tildes ni caracteres raros
 * (`reportes-rivera-semanas-2026-10-21.pdf`). Un título que no deja nada usable cae en «reportes». Es el mismo nombre
 * que armaba el panel (`nombreDeArchivo` de `exportar/contexto.ts`).
 */
export function nombreDeArchivo(titulo: string, granularidad: Granularidad, hoy: string): string {
  const ambito = titulo
    .normalize("NFD")
    .replace(/\p{M}/gu, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 40)
    .replace(/-+$/g, "");
  const grupo = { dia: "dias", semana: "semanas", mes: "meses" }[granularidad];
  return [ambito ? `reportes-${ambito}` : "reportes", grupo, hoy].join("-") + ".pdf";
}

/** Una RPC con la sesión de quien pidió el informe (`Authorization` tal cual llegó). Las fallas salen como `ErrorDeLaBase`. */
export function crearLlamadaRpc(dependencias: Dependencias, autorizacion: string): LlamarRpc {
  return async (nombre, argumentos) => {
    let respuesta: Response;
    try {
      respuesta = await dependencias.fetch(`${dependencias.urlDeLaApi}/rest/v1/rpc/${nombre}`, {
        method: "POST",
        headers: {
          apikey: dependencias.clavePublica,
          Authorization: autorizacion,
          "Content-Type": "application/json",
          Accept: "application/json",
        },
        body: JSON.stringify(argumentos),
      });
    } catch {
      throw new ErrorDeLaBase("red", 0, `No hubo respuesta de ${nombre}`);
    }
    if (!respuesta.ok) {
      let codigo = String(respuesta.status);
      try {
        const cuerpo: unknown = await respuesta.json();
        if (esObjeto(cuerpo) && typeof cuerpo.code === "string") codigo = cuerpo.code;
      } catch {
        // Sin cuerpo entendible: queda el estado HTTP como código.
      }
      throw new ErrorDeLaBase(codigo, respuesta.status, `${nombre} respondió ${respuesta.status}`);
    }
    try {
      return await respuesta.json();
    } catch {
      throw new RespuestaInesperada(nombre, "la respuesta no es JSON");
    }
  };
}

/** Qué le decimos a la persona según qué falló. */
function codigoDeError(error: unknown): CodigoDeError {
  if (error instanceof ErrorDeLaBase) {
    // 42501: sin rol de coordinación para esa campaña. 401 / PGRST30x: JWT vencido o inválido.
    if (error.codigo === "42501") return "sin_permiso";
    if (error.http === 401 || error.codigo.startsWith("PGRST30")) return "sin_sesion";
    return "no_se_pudo_leer";
  }
  if (error instanceof RespuestaInesperada) return "no_se_pudo_leer";
  return "no_se_pudo_armar";
}

export async function manejar(pedido: Request, dependencias: Dependencias): Promise<Response> {
  if (pedido.method === "OPTIONS") return new Response(null, { status: 204, headers: CABECERAS_CORS });
  if (pedido.method !== "POST") return errorJson("metodo");

  const autorizacion = pedido.headers.get("Authorization") ?? "";
  if (!/^Bearer\s+\S+$/i.test(autorizacion)) return errorJson("sin_sesion");

  const largo = Number(pedido.headers.get("Content-Length") ?? "0");
  if (largo > MAXIMO_DEL_CUERPO) return errorJson("pedido_muy_grande");
  let crudo: string;
  try {
    crudo = await pedido.text();
  } catch {
    return errorJson("pedido_invalido");
  }
  if (crudo.length > MAXIMO_DEL_CUERPO) return errorJson("pedido_muy_grande");

  let cuerpo: unknown;
  try {
    cuerpo = JSON.parse(crudo);
  } catch {
    return errorJson("pedido_invalido");
  }
  const datosDelPedido = leerPedido(cuerpo);
  if (!datosDelPedido) return errorJson("pedido_invalido");

  try {
    const hoy = hoyEnMontevideo(dependencias.ahora());
    const datos = await leerDatos(crearLlamadaRpc(dependencias, autorizacion), datosDelPedido.campaniaId, hoy);
    if (!datos) return errorJson("sin_campania");

    const reporte = armarReporte(datos, datosDelPedido.ambito, datosDelPedido.granularidad);
    if (!reporte.tabla.filas.some((f) => f.tipo === "fila")) return errorJson("sin_datos");

    const archivo = nombreDeArchivo(reporte.titulo, datosDelPedido.granularidad, hoy);
    const pdf = await crearInformePdf(
      reporte,
      { granularidad: datosDelPedido.granularidad, hoy, campania: datos.campania.nombre },
      archivo,
    );
    return new Response(pdf.slice(), {
      status: 200,
      headers: {
        ...CABECERAS_CORS,
        "Content-Type": "application/pdf",
        "Content-Disposition": `attachment; filename="${archivo}"`,
        "Content-Length": String(pdf.byteLength),
        "Cache-Control": "no-store",
      },
    });
  } catch (error) {
    const codigo = codigoDeError(error);
    // Solo el tipo de falla y su código: nada del pedido ni de lo leído (nombres de colportores, ids).
    console.error(JSON.stringify({
      evento: "informe-reportes.fallo",
      codigo,
      origen: error instanceof ErrorDeLaBase ? error.codigo : (error as Error)?.name,
    }));
    return errorJson(codigo);
  }
}
