import { type Mundo, rpcDe } from "./apoyo.ts";
import { ErrorDeLaBase } from "./datos.ts";
import type { Dependencias } from "./handler.ts";

export const URL_DE_LA_API = "https://proyecto.supabase.test";
export const CLAVE_PUBLICA = "clave-publica-de-prueba";
export const AHORA = new Date("2026-10-21T15:00:00Z");

export interface PedidoRegistrado {
  url: string;
  autorizacion: string | null;
  apikey: string | null;
  metodo: string;
  cuerpo: string;
}

/** Un `fetch` que contesta como PostgREST lo que contestaría el mundo de prueba, y anota qué se le pidió. */
export function dependenciasDe(mundo: Mundo, ajustes: Partial<Dependencias> = {}) {
  const { llamar } = rpcDe(mundo);
  const pedidos: PedidoRegistrado[] = [];
  const fetchFalso: typeof fetch = async (entrada, init) => {
    const url = String(entrada);
    const cabeceras = new Headers(init?.headers);
    pedidos.push({
      url,
      autorizacion: cabeceras.get("Authorization"),
      apikey: cabeceras.get("apikey"),
      metodo: init?.method ?? "GET",
      cuerpo: String(init?.body ?? ""),
    });
    const nombre = url.slice(`${URL_DE_LA_API}/rest/v1/rpc/`.length);
    try {
      const cuerpo = await llamar(nombre, JSON.parse(String(init?.body ?? "{}")));
      return new Response(JSON.stringify(cuerpo), { status: 200, headers: { "Content-Type": "application/json" } });
    } catch (error) {
      if (error instanceof ErrorDeLaBase) {
        return new Response(JSON.stringify({ code: error.codigo, message: "mensaje de la base" }), {
          status: error.http,
          headers: { "Content-Type": "application/json" },
        });
      }
      throw error;
    }
  };
  const dependencias: Dependencias = {
    fetch: fetchFalso,
    urlDeLaApi: URL_DE_LA_API,
    clavePublica: CLAVE_PUBLICA,
    ahora: () => AHORA,
    ...ajustes,
  };
  return { dependencias, pedidos };
}

export function pedidoDeInforme(
  cuerpo: unknown,
  cabeceras: Record<string, string> = { Authorization: "Bearer jwt-de-la-coordinadora" },
) {
  return new Request("https://proyecto.supabase.test/functions/v1/informe-reportes", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...cabeceras },
    body: typeof cuerpo === "string" ? cuerpo : JSON.stringify(cuerpo),
  });
}
