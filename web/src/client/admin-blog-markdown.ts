// Blog düzenleyicisinin önizlemesi: Markdown `marked`'ın sözcük çözümleyicisiyle parçalara ayrılır ve DOM öğeleri
// doğrudan kurulur (`innerHTML` yok). Metinler `textContent` ile yazılır: Markdown içindeki HTML olduğu gibi metin olarak
// görünür, çalışmaz. Bağlantılar yalnızca http(s) ya da site içi (`/…`) adreslerse bağlantı olur, değilse düz metin;
// görseller yalnızca site içindeyse gösterilir (yönetim sayfasının CSP'si dış görsele izin vermez), dış görselin yerine
// kısa bir not yazılır. Bu oturumda yüklenen görseller site henüz yeniden derlenmediği için tarayıcıdaki kopyalarından
// (`blob:` adresi) gösterilir. Önizleme yaklaşıktır: yayımlanan sayfayı Astro derler.
import { type MarkedToken, type Token, type Tokens, lexer } from "marked";
import { fill } from "./copy";

/** Önizlemenin metinleri ve bu oturumda yüklenen görseller. */
export interface PreviewOptions {
  /** `{alt}`: gösterilmeyen dış görsel. */
  readonly image: string;
  /** Sitedeki yol (`/blog/<kısa ad>/<ad>.webp`) → tarayıcıdaki kopyanın `blob:` adresi. */
  readonly localImages: ReadonlyMap<string, string>;
}

/**
 * `marked` uzantısız kullanıldığında yalnızca yerleşik parçalar üretir; tür birliğindeki genel parça (`Tokens.Generic`)
 * yalnızca uzantılar içindir. Tanınmayan parça türü, kaynağı (`raw`) metin olarak çizilir.
 */
function known(token: Token): MarkedToken {
  return token as MarkedToken;
}

/** Bağlantı adresi güvenli mi: http(s) ya da site içi yol (`//` ile başlayan dış adres değil). Saf fonksiyondur. */
export function isSafeHref(href: string): boolean {
  if (href.startsWith("/")) {
    return !href.startsWith("//") && !href.startsWith("/\\");
  }
  if (!URL.canParse(href)) {
    return false;
  }
  const protocol: string = new URL(href).protocol;
  return protocol === "https:" || protocol === "http:";
}

/** Görsel önizlemede gösterilebilir mi: yalnızca site içi yol. Saf fonksiyondur. */
function isSiteImage(href: string): boolean {
  return href.startsWith("/") && !href.startsWith("//") && !href.startsWith("/\\");
}

/** Sınıfsız yeni öğe; çocukları eklenmiş. */
function elementWith<Tag extends keyof HTMLElementTagNameMap>(tag: Tag, children: readonly Node[]): HTMLElementTagNameMap[Tag] {
  const created: HTMLElementTagNameMap[Tag] = document.createElement(tag);
  created.append(...children);
  return created;
}

/** Satır içi parçaların düğümleri. */
function inlineNodes(tokens: readonly Token[], text: PreviewOptions): Node[] {
  return tokens.map((token: Token): Node => inlineNode(known(token), text));
}

/** Satır içi parça (metin, vurgu, kod, bağlantı, görsel, satır sonu). */
function inlineNode(token: MarkedToken, text: PreviewOptions): Node {
  switch (token.type) {
    case "strong":
      return elementWith("strong", inlineNodes(token.tokens, text));
    case "em":
      return elementWith("em", inlineNodes(token.tokens, text));
    case "del":
      return elementWith("del", inlineNodes(token.tokens, text));
    case "codespan":
      return elementWith("code", [document.createTextNode(token.text)]);
    case "br":
      return document.createElement("br");
    case "link": {
      const children: Node[] = inlineNodes(token.tokens, text);
      if (!isSafeHref(token.href)) {
        return elementWith("span", children);
      }
      const link: HTMLAnchorElement = elementWith("a", children);
      link.href = token.href;
      link.target = "_blank";
      link.rel = "noopener noreferrer";
      return link;
    }
    case "image": {
      if (!isSiteImage(token.href)) {
        const note: HTMLSpanElement = elementWith("span", [document.createTextNode(fill(text.image, { alt: token.text }))]);
        note.className = "muted";
        return note;
      }
      const image: HTMLImageElement = document.createElement("img");
      image.src = text.localImages.get(token.href) ?? token.href;
      image.alt = token.text;
      return image;
    }
    case "text":
      return token.tokens === undefined ? document.createTextNode(token.text) : elementWith("span", inlineNodes(token.tokens, text));
    case "checkbox":
      return document.createTextNode(token.checked ? "[x] " : "[ ] ");
    default:
      // HTML ve kaçış parçaları dahil geri kalan her şey yazıldığı gibi metindir.
      return document.createTextNode("text" in token && typeof token.text === "string" ? token.text : token.raw);
  }
}

/** Blok parçaların düğümleri (boşluk ve bağlantı tanımları çizilmez). */
function blockNodes(tokens: readonly Token[], text: PreviewOptions): Node[] {
  return tokens.map((token: Token): Node | null => blockNode(known(token), text)).filter((node: Node | null): node is Node => node !== null);
}

/** Tablo hücresi. */
function tableCell(cell: Tokens.TableCell, text: PreviewOptions): HTMLTableCellElement {
  return elementWith(cell.header ? "th" : "td", inlineNodes(cell.tokens, text));
}

/** Blok parça (başlık, paragraf, liste, alıntı, kod, tablo, çizgi); çizilmeyen parçada null. */
function blockNode(token: MarkedToken, text: PreviewOptions): Node | null {
  switch (token.type) {
    case "space":
    case "def":
      return null;
    case "heading": {
      const level: 1 | 2 | 3 | 4 | 5 | 6 = Math.min(6, Math.max(1, token.depth)) as 1 | 2 | 3 | 4 | 5 | 6;
      return elementWith(`h${level}`, inlineNodes(token.tokens, text));
    }
    case "paragraph":
      return elementWith("p", inlineNodes(token.tokens, text));
    case "blockquote":
      return elementWith("blockquote", blockNodes(token.tokens, text));
    case "code":
      return elementWith("pre", [elementWith("code", [document.createTextNode(token.text)])]);
    case "hr":
      return document.createElement("hr");
    case "list": {
      const list: HTMLOListElement | HTMLUListElement = elementWith(
        token.ordered ? "ol" : "ul",
        token.items.map((item: Tokens.ListItem): HTMLLIElement => elementWith("li", blockNodes(item.tokens, text))),
      );
      if (list instanceof HTMLOListElement && typeof token.start === "number" && token.start !== 1) {
        list.start = token.start;
      }
      return list;
    }
    case "table": {
      const head: HTMLTableSectionElement = elementWith("thead", [elementWith("tr", token.header.map((cell: Tokens.TableCell): HTMLTableCellElement => tableCell(cell, text)))]);
      const body: HTMLTableSectionElement = elementWith(
        "tbody",
        token.rows.map((row: Tokens.TableCell[]): HTMLTableRowElement => elementWith("tr", row.map((cell: Tokens.TableCell): HTMLTableCellElement => tableCell(cell, text)))),
      );
      const wrap: HTMLDivElement = elementWith("div", [elementWith("table", [head, body])]);
      wrap.className = "table-wrap";
      return wrap;
    }
    case "html":
      // Ham HTML çalıştırılmaz: kaynağı metin olarak gösterilir.
      return elementWith("p", [document.createTextNode(token.raw)]);
    default:
      return inlineNode(token, text);
  }
}

/** Markdown'ın önizleme düğümleri (GFM, `marked` varsayılanları). */
export function markdownPreview(source: string, text: PreviewOptions): Node[] {
  return blockNodes(lexer(source, { gfm: true }), text);
}
