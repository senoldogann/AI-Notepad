// Vite'ın `?raw` içe aktarımı: dosyanın metni (blog testleri sitedeki gerçek yazıları okur).
declare module "*.md?raw" {
  const text: string;
  export default text;
}
