import { decodePDFRawStream, PDFArray, PDFDocument, PDFRawStream } from "pdf-lib";

/** Los textos que dibuja cada página de un PDF (los de `drawText`, en hexadecimal WinAnsi), para probar el archivo real. */
export async function textosDelPdf(bytes: Uint8Array): Promise<string[][]> {
  const documento = await PDFDocument.load(bytes);
  return documento.getPages().map((pagina) => {
    const contenido = pagina.node.Contents();
    const referencias = contenido instanceof PDFArray ? contenido.asArray() : contenido ? [contenido] : [];
    const textos: string[] = [];
    for (const referencia of referencias) {
      const flujo = documento.context.lookup(referencia);
      if (!(flujo instanceof PDFRawStream)) continue;
      const crudo = new TextDecoder("latin1").decode(decodePDFRawStream(flujo).decode());
      for (const [, hexa] of crudo.matchAll(/<([0-9A-Fa-f]+)>\s*Tj/g)) {
        const pares = hexa.match(/../g) ?? [];
        textos.push(pares.map((p) => String.fromCharCode(parseInt(p, 16))).join(""));
      }
    }
    return textos;
  });
}
