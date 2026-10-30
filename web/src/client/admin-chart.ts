// Yönetim panelinin grafikleri: günlük çubuk (yığılmış) ve çizgi grafikleri, özet kutularındaki küçük eğri. Satır içi
// SVG, kütüphanesiz; satır içi stil yoktur (CSP): yükseklik ve konum SVG nitelikleridir, renk ve boyut CSS'tedir.
// Grafiğin üstünde dönemin değeri (toplam ya da son değer) durur; imleç ya da ok tuşlarıyla bir güne gelince aynı
// yerde o günün değeri ve tarihi görünür (açılır kutu yok). Eksen: y'de üst sınır, yarısı ve sıfır; x'te ilk, orta ve
// son gün. İşaretleme ChartPanel.astro'dadır: `chart-<id>` çizim alanı, `chart-<id>-value` değer, `chart-<id>-summary`
// açıklama.
import { formatCount, formatDay } from "./admin-format";
import { type AdminLayoutCopy, adminLayoutCopy } from "./admin-layout-copy";
import { fill } from "./copy";
import { element } from "./dom";

const periods: AdminLayoutCopy["periods"] = adminLayoutCopy.periods;

const svgNamespace: string = "http://www.w3.org/2000/svg";

/** Bir günün SVG genişliği (görünüm kutusu birimi) ve çubuğun bu genişlikteki payı. */
const slotWidth: number = 10;
const barShare: number = 0.68;
/** Çizim alanının SVG yüksekliği (yüzde gibi: 0 üst, 100 taban). */
const plotHeight: number = 100;

/** Serinin rengi: ana seri ve ikinci seri. */
export type ChartTone = "main" | "accent";

/** Günün bir parçası (yığılmış çubukta alttan üste): değer, renk ve okumadaki adı. */
export interface ChartPart {
  readonly value: number;
  readonly tone: ChartTone;
  readonly label: string;
}

/** Grafiğin bir günü; verisi yoksa (`parts` null) çubuk ya da çizgi çizilmez. */
export interface ChartPoint {
  readonly day: string;
  readonly parts: readonly ChartPart[] | null;
}

/** Grafik türü: günlük çubuklar ya da (anlık görüntü serileri için) çizgi. */
export type ChartKind = "bars" | "line";

/** Çizilecek grafik. */
export interface ChartSpec {
  readonly id: string;
  readonly kind: ChartKind;
  readonly points: readonly ChartPoint[];
  readonly format: (value: number) => string;
  /** Başlıktaki değer: dönemin toplamı ya da son değer. */
  readonly headline: string;
  /** Değerin altındaki açıklama ("30 days", "Latest · 29 Oct"). */
  readonly caption: string;
}

/** Günün toplamı (verisiz gün null). Saf fonksiyondur. */
function pointTotal(point: ChartPoint): number | null {
  return point.parts === null ? null : point.parts.reduce((sum: number, part: ChartPart): number => sum + part.value, 0);
}

/** Serinin toplamı (verisiz günler sayılmaz). Saf fonksiyondur. */
export function chartTotal(points: readonly ChartPoint[]): number {
  return points.reduce((sum: number, point: ChartPoint): number => sum + (pointTotal(point) ?? 0), 0);
}

/** Verisi olan son gün; yoksa null. Saf fonksiyondur. */
export function lastPoint(points: readonly ChartPoint[]): ChartPoint | null {
  return [...points].reverse().find((point: ChartPoint): boolean => point.parts !== null) ?? null;
}

/**
 * Eksenin üst sınırı: en büyük değerin üstündeki yuvarlak çift sayı (1, 2, 4, 6, 8 × 10ⁿ; yarısı da yuvarlak). Tamsayı
 * serisinde en az 2'dir (yarısı kesirli olmasın); değer yoksa 1. Saf fonksiyondur.
 */
export function niceCeiling(max: number, integers: boolean): number {
  if (max <= 0) {
    return integers ? 2 : 1;
  }
  const magnitude: number = 10 ** Math.floor(Math.log10(max));
  const step: number | undefined = [1, 2, 4, 6, 8, 10].find((candidate: number): boolean => candidate * magnitude >= max);
  const ceiling: number = (step ?? 10) * magnitude;
  return integers ? Math.max(2, ceiling) : ceiling;
}

/** Serinin tüm değerleri tamsayı mı. Saf fonksiyondur. */
function integerSeries(points: readonly ChartPoint[]): boolean {
  return points.every((point: ChartPoint): boolean => (point.parts ?? []).every((part: ChartPart): boolean => Number.isInteger(part.value)));
}

/** SVG öğesi oluşturur. */
function svgElement(name: string, attributes: Readonly<Record<string, string>>): SVGElement {
  const created: SVGElement = document.createElementNS(svgNamespace, name) as SVGElement;
  for (const [key, value] of Object.entries(attributes)) {
    created.setAttribute(key, value);
  }
  return created;
}

/** Metinli `span`. */
function span(text: string): HTMLSpanElement {
  const created: HTMLSpanElement = document.createElement("span");
  created.textContent = text;
  return created;
}

/** Yatay kılavuz çizgileri (üst, orta, taban). */
function gridLines(width: number): SVGElement[] {
  return [0, plotHeight / 2, plotHeight].map(
    (y: number): SVGElement =>
      svgElement("line", { x1: "0", x2: String(width), y1: String(y), y2: String(y), class: y === plotHeight ? "chart__baseline" : "chart__gridline", "vector-effect": "non-scaling-stroke" }),
  );
}

/** Günlük yığılmış çubuklar; her gün bir grup (`data-index`). */
function barGroups(points: readonly ChartPoint[], ceiling: number): SVGElement[] {
  const barWidth: number = slotWidth * barShare;
  return points.map((point: ChartPoint, index: number): SVGElement => {
    const group: SVGElement = svgElement("g", { class: "chart__slot", "data-index": String(index) });
    let top: number = plotHeight;
    for (const part of point.parts ?? []) {
      if (part.value <= 0) {
        continue;
      }
      const height: number = Math.max(1.2, (part.value / ceiling) * plotHeight);
      top -= height;
      group.append(
        svgElement("rect", {
          x: (index * slotWidth + (slotWidth - barWidth) / 2).toFixed(2),
          y: top.toFixed(2),
          width: barWidth.toFixed(2),
          height: height.toFixed(2),
          class: `chart__bar chart__bar--${part.tone}`,
        }),
      );
    }
    return group;
  });
}

/** Çizginin yolu ve altındaki alan; verisiz günlerde çizgi kesilir. */
function linePaths(points: readonly ChartPoint[], ceiling: number): SVGElement[] {
  const runs: { x: number; y: number }[][] = [];
  let current: { x: number; y: number }[] = [];
  points.forEach((point: ChartPoint, index: number): void => {
    const total: number | null = pointTotal(point);
    if (total === null) {
      if (current.length > 0) {
        runs.push(current);
      }
      current = [];
      return;
    }
    current.push({ x: index * slotWidth + slotWidth / 2, y: plotHeight - (total / ceiling) * plotHeight });
  });
  if (current.length > 0) {
    runs.push(current);
  }
  return runs.flatMap((run: { x: number; y: number }[]): SVGElement[] => {
    const first: { x: number; y: number } | undefined = run[0];
    const last: { x: number; y: number } | undefined = run.at(-1);
    if (first === undefined || last === undefined) {
      return [];
    }
    // Tek günlük parça görünsün diye en az bir gün genişliğinde çizilir.
    const line: string = run.length === 1 ? `M${first.x - slotWidth / 2},${first.y}L${first.x + slotWidth / 2},${first.y}` : run.map((p, i: number): string => `${i === 0 ? "M" : "L"}${p.x.toFixed(2)},${p.y.toFixed(2)}`).join("");
    const startX: number = run.length === 1 ? first.x - slotWidth / 2 : first.x;
    const endX: number = run.length === 1 ? first.x + slotWidth / 2 : last.x;
    const area: string = `${line}L${endX.toFixed(2)},${plotHeight}L${startX.toFixed(2)},${plotHeight}Z`;
    return [
      svgElement("path", { d: area, class: "chart__area" }),
      svgElement("path", { d: line, class: "chart__line", "vector-effect": "non-scaling-stroke" }),
    ];
  });
}

/** Okuma satırı: günün değeri ve (birden çok parçada) parçaların dökümüyle tarihi. Saf fonksiyondur. */
function readout(point: ChartPoint, format: (value: number) => string, none: string): { readonly value: string; readonly caption: string } {
  const total: number | null = pointTotal(point);
  const parts: readonly ChartPart[] = point.parts ?? [];
  const breakdown: string = parts.length > 1 ? parts.map((part: ChartPart): string => `${part.label} ${format(part.value)}`).join(" · ") : "";
  return { value: total === null ? none : format(total), caption: breakdown === "" ? formatDay(point.day) : `${formatDay(point.day)} · ${breakdown}` };
}

/**
 * Grafiği çizer, başlıktaki değeri ve açıklamayı yazar, okumayı (imleç ve ok tuşları) bağlar. Dinleyiciler özellik
 * olarak atanır: yeniden çizim eskilerinin yerine geçer, birikmez.
 */
export function renderChart(spec: ChartSpec): void {
  const plot: HTMLElement = element(`chart-${spec.id}`, HTMLElement);
  const valueNode: HTMLElement = element(`chart-${spec.id}-value`, HTMLElement);
  const captionNode: HTMLElement = element(`chart-${spec.id}-summary`, HTMLElement);
  // Hiç veri yoksa (anlık görüntü henüz yok, kayıt yok) boş eksen yerine aynı yükseklikte bir bildirim durur.
  if (!spec.points.some((point: ChartPoint): boolean => point.parts !== null)) {
    const empty: HTMLElement = document.createElement("p");
    empty.className = "chart__empty";
    empty.textContent = periods.noData;
    plot.replaceChildren(empty);
    plot.removeAttribute("tabindex");
    plot.onpointermove = null;
    plot.onpointerleave = null;
    plot.onblur = null;
    plot.onkeydown = null;
    valueNode.textContent = "—";
    captionNode.textContent = "";
    return;
  }
  const totals: (number | null)[] = spec.points.map(pointTotal);
  const ceiling: number = niceCeiling(Math.max(0, ...totals.map((total: number | null): number => total ?? 0)), integerSeries(spec.points));
  const width: number = Math.max(1, spec.points.length) * slotWidth;

  const svg: SVGElement = svgElement("svg", {
    viewBox: `0 0 ${width} ${plotHeight}`,
    preserveAspectRatio: "none",
    class: `chart__svg chart__svg--${spec.kind}`,
    role: "img",
    "aria-label": `${spec.headline} · ${spec.caption}`,
  });
  const cursor: SVGElement = svgElement("line", { x1: "0", x2: "0", y1: "0", y2: String(plotHeight), class: "chart__cursor", "vector-effect": "non-scaling-stroke" });
  svg.append(...gridLines(width), ...(spec.kind === "bars" ? barGroups(spec.points, ceiling) : linePaths(spec.points, ceiling)), cursor);

  const yAxis: HTMLElement = document.createElement("div");
  yAxis.className = "chart__y";
  yAxis.setAttribute("aria-hidden", "true");
  yAxis.append(span(spec.format(ceiling)), span(spec.format(ceiling / 2)), span(spec.format(0)));
  const xAxis: HTMLElement = document.createElement("div");
  xAxis.className = "chart__x";
  xAxis.setAttribute("aria-hidden", "true");
  const middle: ChartPoint | undefined = spec.points[Math.floor((spec.points.length - 1) / 2)];
  xAxis.append(...[spec.points[0], middle, spec.points.at(-1)].map((point: ChartPoint | undefined): HTMLSpanElement => span(point === undefined ? "" : formatDay(point.day))));
  const canvas: HTMLElement = document.createElement("div");
  canvas.className = "chart__canvas";
  canvas.append(svg);
  const area: HTMLElement = document.createElement("div");
  area.className = "chart__area-wrap";
  area.append(canvas, xAxis);
  plot.replaceChildren(yAxis, area);

  valueNode.textContent = spec.headline;
  captionNode.textContent = spec.caption;
  const none: string = "—";
  const state: { index: number | null } = { index: null };
  const show = (index: number | null): void => {
    state.index = index;
    svg.classList.toggle("is-reading", index !== null);
    for (const slot of Array.from(svg.querySelectorAll<SVGElement>(".chart__slot"))) {
      slot.classList.toggle("is-active", slot.dataset["index"] === String(index));
    }
    const point: ChartPoint | undefined = index === null ? undefined : spec.points[index];
    if (index === null || point === undefined) {
      valueNode.textContent = spec.headline;
      captionNode.textContent = spec.caption;
      return;
    }
    const center: string = (index * slotWidth + slotWidth / 2).toFixed(2);
    cursor.setAttribute("x1", center);
    cursor.setAttribute("x2", center);
    const read: { readonly value: string; readonly caption: string } = readout(point, spec.format, none);
    valueNode.textContent = read.value;
    captionNode.textContent = read.caption;
  };
  plot.tabIndex = 0;
  plot.onpointermove = (event: PointerEvent): void => {
    const bounds: DOMRect = canvas.getBoundingClientRect();
    if (bounds.width === 0 || spec.points.length === 0) {
      return;
    }
    const ratio: number = (event.clientX - bounds.left) / bounds.width;
    show(ratio < 0 || ratio > 1 ? null : Math.min(spec.points.length - 1, Math.floor(ratio * spec.points.length)));
  };
  plot.onpointerleave = (): void => show(null);
  plot.onblur = (): void => show(null);
  plot.onkeydown = (event: KeyboardEvent): void => {
    if (spec.points.length === 0) {
      return;
    }
    if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
      event.preventDefault();
      const step: number = event.key === "ArrowLeft" ? -1 : 1;
      const start: number = state.index ?? (step === 1 ? -1 : spec.points.length);
      show(Math.max(0, Math.min(spec.points.length - 1, start + step)));
    }
    if (event.key === "Escape") {
      show(null);
    }
  };
}

/** Özet kutusundaki küçük eğri (`kpi-<id>-spark`): verisiz günlerde kesilen çizgi ve altındaki alan. */
export function renderSparkline(id: string, values: readonly (number | null)[]): void {
  const holder: HTMLElement = element(`kpi-${id}-spark`, HTMLElement);
  // Verisi olmayan eğri çizilmez (anlık görüntü henüz yokken boş bir alan kalmasın).
  if (values.every((value: number | null): boolean => value === null)) {
    holder.replaceChildren();
    return;
  }
  const points: ChartPoint[] = values.map((value: number | null, index: number): ChartPoint => ({ day: String(index), parts: value === null ? null : [{ value, tone: "main", label: "" }] }));
  // Eğri kutunun yüksekliğini kullanır: üst sınır en büyük değerin biraz üstü (yuvarlak sayı değil).
  const max: number = Math.max(0, ...values.map((value: number | null): number => value ?? 0));
  const ceiling: number = max > 0 ? max * 1.12 : 1;
  const width: number = Math.max(1, values.length) * slotWidth;
  const svg: SVGElement = svgElement("svg", { viewBox: `0 0 ${width} ${plotHeight}`, preserveAspectRatio: "none", class: "spark", "aria-hidden": "true" });
  svg.append(...linePaths(points, ceiling));
  holder.replaceChildren(svg);
}

/** Günlük sayıların çubuk grafiği: başlıkta dönemin toplamı. */
export function renderDailyBars(id: string, points: readonly ChartPoint[], format: (value: number) => string): void {
  renderChart({ id, kind: "bars", points, format, headline: format(chartTotal(points)), caption: fill(periods.lastDays, { days: formatCount(points.length) }) });
}

/** Anlık görüntü serisinin grafiği (çizgi ya da yığılmış çubuk): başlıkta son değer ve günü. */
export function renderSnapshots(id: string, kind: ChartKind, points: readonly ChartPoint[], format: (value: number) => string): void {
  const last: ChartPoint | null = lastPoint(points);
  const total: number | null = last === null ? null : pointTotal(last);
  renderChart({
    id,
    kind,
    points,
    format,
    headline: total === null ? "—" : format(total),
    caption: last === null ? periods.noData : fill(periods.latest, { day: formatDay(last.day) }),
  });
}
