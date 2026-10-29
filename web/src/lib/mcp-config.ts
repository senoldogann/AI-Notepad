// MCP sayfasındaki örnek yapılandırma. Uygulamanın Ayarlar › Bağlantılar › "Diğer MCP istemcileri" bölümünde kopyaladığı
// metinle aynı biçimdedir (App/SettingsPage.swift `mcpClientConfig`): sunucu adı görünen addan
// (Packages/.../Integrations/MCPClients.swift `mcpServerName`), komut uygulamanın çalıştırılabilir dosyası, tek argüman
// `--mcp`. Uygulama paketinin ve çalıştırılabilir dosyanın adı ürün adıdır (project.yml `PRODUCT_NAME`).

/** Yapılandırmadaki sunucu adı: görünen ad küçük harfle, boşluklar tireyle. Saf fonksiyondur. */
export function mcpServerName(appName: string): string {
  return appName.toLowerCase().replaceAll(" ", "-");
}

/** Uygulamalar klasöründeki uygulamanın çalıştırılabilir dosyası. Saf fonksiyondur. */
export function applicationsExecutablePath(appName: string): string {
  return `/Applications/${appName}.app/Contents/MacOS/${appName}`;
}

/**
 * Uygulamanın kopyaladığı yapılandırma metni, satır satır aynı biçimde (`mcpServers` anahtarıyla; Claude Desktop,
 * Cursor ve çoğu istemci). Değerler JSON olarak kaçışlanır. Saf fonksiyondur.
 */
export function mcpClientConfigText(appName: string): string {
  return [
    "{",
    '  "mcpServers": {',
    `    ${JSON.stringify(mcpServerName(appName))}: {`,
    `      "command": ${JSON.stringify(applicationsExecutablePath(appName))},`,
    '      "args": ["--mcp"]',
    "    }",
    "  }",
    "}",
  ].join("\n");
}
