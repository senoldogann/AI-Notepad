/** Bozuk ya da beklenmeyen DER yapısı. */
export class DerError extends Error {
  override readonly name: string = "DerError";
}

/** DER öğesi: etiket baytı, içerik ve öğenin bittiği konum. */
interface DerNode {
  readonly tag: number;
  readonly content: Uint8Array;
  readonly end: number;
}

/** `offset` konumundaki tek DER öğesini okur (yalnızca kesin uzunluk). Saf fonksiyondur. */
function readNode(bytes: Uint8Array, offset: number): DerNode {
  const tag: number | undefined = bytes[offset];
  const firstLength: number | undefined = bytes[offset + 1];
  if (tag === undefined || firstLength === undefined) {
    throw new DerError("DER öğesi eksik");
  }
  let length: number;
  let headerLength: number;
  if (firstLength < 0x80) {
    length = firstLength;
    headerLength = 2;
  } else {
    const lengthBytes: number = firstLength & 0x7f;
    if (lengthBytes === 0 || lengthBytes > 4) {
      throw new DerError("DER uzunluğu desteklenmiyor");
    }
    length = 0;
    for (let index: number = 0; index < lengthBytes; index += 1) {
      const byte: number | undefined = bytes[offset + 2 + index];
      if (byte === undefined) {
        throw new DerError("DER uzunluğu eksik");
      }
      length = length * 256 + byte;
    }
    headerLength = 2 + lengthBytes;
  }
  const start: number = offset + headerLength;
  const end: number = start + length;
  if (end > bytes.byteLength) {
    throw new DerError("DER içeriği eksik");
  }
  return { tag, content: bytes.subarray(start, end), end };
}

/** Ardışık DER öğelerinin tümü. Saf fonksiyondur. */
function readNodes(bytes: Uint8Array): DerNode[] {
  const nodes: DerNode[] = [];
  let offset: number = 0;
  while (offset < bytes.byteLength) {
    const node: DerNode = readNode(bytes, offset);
    nodes.push(node);
    offset = node.end;
  }
  return nodes;
}

/** Yapılı (constructed) öğelerin içine inerek bütün OCTET STRING içeriklerini toplar. Saf fonksiyondur. */
function collectOctetStrings(bytes: Uint8Array): Uint8Array[] {
  return readNodes(bytes).flatMap((node: DerNode): Uint8Array[] => {
    if (node.tag === 0x04) {
      return [node.content];
    }
    const constructed: boolean = (node.tag & 0x20) !== 0;
    return constructed ? collectOctetStrings(node.content) : [];
  });
}

/**
 * Apple uzantı değerindeki (DER SEQUENCE) tek OCTET STRING'i döndürür; Apple'ın nonce (1.2.840.113635.100.8.2) ve
 * aclBlob (1.2.840.113635.100.8.6) uzantıları bu biçimdedir. Sıfır ya da birden çok varsa `DerError`.
 */
export function singleOctetString(der: Uint8Array): Uint8Array {
  const strings: Uint8Array[] = collectOctetStrings(der);
  if (strings.length !== 1 || strings[0] === undefined) {
    throw new DerError(`Tek OCTET STRING bekleniyordu, ${strings.length} bulundu`);
  }
  return strings[0];
}

/** DER ECDSA imzasını (SEQUENCE {r, s}) WebCrypto'nun beklediği r||s biçimine çevirir. Saf fonksiyondur. */
export function derEcdsaSignatureToRaw(der: Uint8Array, coordinateLength: number): Uint8Array {
  const sequence: DerNode = readNode(der, 0);
  if (sequence.tag !== 0x30 || sequence.end !== der.byteLength) {
    throw new DerError("ECDSA imzası SEQUENCE değil");
  }
  const parts: DerNode[] = readNodes(sequence.content);
  if (parts.length !== 2 || parts.some((part: DerNode): boolean => part.tag !== 0x02)) {
    throw new DerError("ECDSA imzası iki INTEGER içermiyor");
  }
  const raw: Uint8Array = new Uint8Array(coordinateLength * 2);
  parts.forEach((part: DerNode, index: number): void => {
    let value: Uint8Array = part.content;
    while (value.byteLength > coordinateLength && value[0] === 0) {
      value = value.subarray(1);
    }
    if (value.byteLength > coordinateLength) {
      throw new DerError("ECDSA imza bileşeni çok uzun");
    }
    raw.set(value, index * coordinateLength + (coordinateLength - value.byteLength));
  });
  return raw;
}
