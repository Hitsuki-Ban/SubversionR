const HEADER_SEPARATOR = "\r\n\r\n";
const HEADER_SEPARATOR_BYTES = Buffer.from(HEADER_SEPARATOR, "utf8");

export function encodeContentLengthFrame(payload: string): string {
  const length = Buffer.byteLength(payload, "utf8");
  return `Content-Length: ${length}${HEADER_SEPARATOR}${payload}`;
}

export function decodeContentLengthFrame(frame: string): string {
  const separatorIndex = frame.indexOf(HEADER_SEPARATOR);
  if (separatorIndex < 0) {
    throw new Error("Missing Content-Length header");
  }

  const header = frame.slice(0, separatorIndex);
  const match = /^Content-Length: (?<length>\d+)$/u.exec(header);
  if (!match?.groups?.length) {
    throw new Error("Invalid Content-Length header");
  }

  const payload = frame.slice(separatorIndex + HEADER_SEPARATOR.length);
  const expectedLength = Number.parseInt(match.groups.length, 10);
  const actualLength = Buffer.byteLength(payload, "utf8");
  if (actualLength !== expectedLength) {
    throw new Error(`Content-Length mismatch: expected ${expectedLength}, got ${actualLength}`);
  }

  return payload;
}

export class ContentLengthFrameDecoder {
  private buffer = Buffer.alloc(0);

  public push(chunk: Buffer): string[] {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    const payloads: string[] = [];

    while (true) {
      const headerEnd = this.buffer.indexOf(HEADER_SEPARATOR_BYTES);
      if (headerEnd < 0) {
        break;
      }

      const header = this.buffer.subarray(0, headerEnd).toString("utf8");
      const match = /^Content-Length: (?<length>\d+)$/u.exec(header);
      if (!match?.groups?.length) {
        throw new Error("Invalid Content-Length header");
      }

      const length = Number.parseInt(match.groups.length, 10);
      const payloadStart = headerEnd + HEADER_SEPARATOR_BYTES.length;
      const payloadEnd = payloadStart + length;
      if (this.buffer.length < payloadEnd) {
        break;
      }

      payloads.push(this.buffer.subarray(payloadStart, payloadEnd).toString("utf8"));
      this.buffer = this.buffer.subarray(payloadEnd);
    }

    return payloads;
  }
}
