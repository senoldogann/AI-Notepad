// IndexNow anahtar dosyası (`/<anahtar>.txt`): içeriği anahtarın kendisidir; arama motoru bildirimi yapanın siteye sahip
// olduğunu bununla doğrular (scripts/indexnow.ts). Tek kaynak config.ts `indexNowKey`.
import type { APIRoute, GetStaticPaths } from "astro";
import { indexNowKey } from "../config";

export const getStaticPaths = (() => [{ params: { indexNowKey } }]) satisfies GetStaticPaths;

export const GET: APIRoute = (): Response => new Response(indexNowKey, { headers: { "content-type": "text/plain; charset=utf-8" } });
