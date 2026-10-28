import { type SiteConfig, parseWebTarget, siteConfigs } from "./config";

/** Bu derlemenin yapılandırması (`PUBLIC_WEB_TARGET` ile seçilir; tanımsızsa derleme durur). */
export const siteConfig: SiteConfig = siteConfigs[parseWebTarget(import.meta.env.PUBLIC_WEB_TARGET)];
