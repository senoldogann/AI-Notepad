/** İstemci IP'si IPv6 biçiminde ama çözülemiyor (Cloudflare'in `cf-connecting-ip` başlığında beklenmez). */
export class InvalidClientIpError extends Error {
  override readonly name: string = "InvalidClientIpError";
}

/** IPv4 adresi (dört ondalık sekizli). */
const ipv4Pattern: RegExp = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;

/** Bir IPv6 grubu: 1–4 onaltılık basamak. */
const hextetPattern: RegExp = /^[0-9a-f]{1,4}$/;

/** Noktalı IPv4 metnini iki IPv6 grubuna çevirir (IPv4 gömülü IPv6 için); geçersizse null. Saf fonksiyondur. */
function ipv4Hextets(text: string): [number, number] | null {
  const match: RegExpExecArray | null = ipv4Pattern.exec(text);
  if (match === null) {
    return null;
  }
  const octets: number[] = match.slice(1, 5).map((part: string): number => Number(part));
  if (octets.some((octet: number): boolean => octet > 255)) {
    return null;
  }
  const [a, b, c, d] = octets as [number, number, number, number];
  return [a * 256 + b, c * 256 + d];
}

/** IPv6 metnini 8 gruba açar (`::` kısaltması ve sondaki gömülü IPv4 dahil); geçersizse null. Saf fonksiyondur. */
export function expandIpv6(address: string): number[] | null {
  const text: string = address.toLowerCase().split("%")[0] ?? "";
  const halves: string[] = text.split("::");
  if (halves.length > 2) {
    return null;
  }
  const parse = (part: string): number[] | null => {
    if (part.length === 0) {
      return [];
    }
    const groups: string[] = part.split(":");
    const result: number[] = [];
    for (const [index, group] of groups.entries()) {
      if (index === groups.length - 1 && group.includes(".")) {
        const embedded: [number, number] | null = ipv4Hextets(group);
        if (embedded === null) {
          return null;
        }
        result.push(...embedded);
      } else if (hextetPattern.test(group)) {
        result.push(Number.parseInt(group, 16));
      } else {
        return null;
      }
    }
    return result;
  };
  const head: number[] | null = parse(halves[0] ?? "");
  const tail: number[] | null = halves.length === 2 ? parse(halves[1] ?? "") : [];
  if (head === null || tail === null) {
    return null;
  }
  if (halves.length === 1) {
    return head.length === 8 ? head : null;
  }
  const missing: number = 8 - head.length - tail.length;
  return missing < 1 ? null : [...head, ...Array.from({ length: missing }, (): number => 0), ...tail];
}

/**
 * Hız sınırı ve IP özetinin anahtarı. IPv6'da bir abone genellikle bütün bir /64 ağı alır (adresi her istekte
 * değiştirebilir): anahtar /64 önekidir (`2001:db8:1:2::/64`). IPv4 eşlemeli IPv6 (`::ffff:a.b.c.d`) IPv4'e döner;
 * IPv4 ve iki nokta içermeyen değerler (yerelde `local`) olduğu gibi kalır. İki nokta içeren ama çözülemeyen değer
 * `InvalidClientIpError`. Saf fonksiyondur.
 */
export function clientIpKey(clientIp: string): string {
  if (!clientIp.includes(":")) {
    return clientIp;
  }
  const groups: number[] | null = expandIpv6(clientIp);
  if (groups === null) {
    throw new InvalidClientIpError("İstemci IP'si çözülemedi (IPv6 biçimi geçersiz).");
  }
  const isV4Mapped: boolean = groups.slice(0, 5).every((group: number): boolean => group === 0) && groups[5] === 0xffff;
  if (isV4Mapped) {
    const high: number = groups[6] ?? 0;
    const low: number = groups[7] ?? 0;
    return `${high >> 8}.${high & 255}.${low >> 8}.${low & 255}`;
  }
  return `${groups
    .slice(0, 4)
    .map((group: number): string => group.toString(16))
    .join(":")}::/64`;
}
