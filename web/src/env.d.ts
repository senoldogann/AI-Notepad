/// <reference types="astro/client" />

interface ImportMetaEnv {
  /** Derleme hedefi (`local` ya da `production`); npm betikleri ayarlar. */
  readonly PUBLIC_WEB_TARGET: string | undefined;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
