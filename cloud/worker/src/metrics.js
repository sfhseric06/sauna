/**
 * Grafana Cloud metrics writer — Prometheus remote_write format.
 *
 * Implements a minimal Prometheus remote_write client with no external deps:
 *   - Manual Protobuf encoding for WriteRequest / TimeSeries / Label / Sample
 *   - Snappy block encoding using uncompressed literal blocks
 *     (valid Snappy, no actual compression — trades bytes for simplicity)
 *
 * The /api/prom/push endpoint requires Content-Type: application/x-protobuf
 * and Snappy-encoded body. Plain text was silently rejected with 400.
 */

// ── Byte utilities ─────────────────────────────────────────────────────────────

function concatBytes(arrays) {
  const total = arrays.reduce((n, a) => n + a.length, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const a of arrays) { out.set(a, offset); offset += a.length; }
  return out;
}

// ── Protobuf encoding ──────────────────────────────────────────────────────────

// Uses % instead of & to avoid 32-bit truncation for timestamps > 2^31.
function encodeVarint(n) {
  const bytes = [];
  while (n > 127) {
    bytes.push((n % 128) | 0x80);
    n = Math.floor(n / 128);
  }
  bytes.push(n % 128);
  return new Uint8Array(bytes);
}

// Wire type 2: length-delimited (string, bytes, embedded message)
function pbLen(fieldNum, data) {
  return concatBytes([encodeVarint((fieldNum << 3) | 2), encodeVarint(data.length), data]);
}

// Wire type 2: string field
function pbStr(fieldNum, str) {
  return pbLen(fieldNum, new TextEncoder().encode(str));
}

// Wire type 1: double (float64, little-endian)
function pbDouble(fieldNum, value) {
  const buf = new ArrayBuffer(8);
  new DataView(buf).setFloat64(0, value, true);
  return concatBytes([encodeVarint((fieldNum << 3) | 1), new Uint8Array(buf)]);
}

// Wire type 0: varint (int64, uint64, bool, enum)
function pbVarint(fieldNum, value) {
  return concatBytes([encodeVarint((fieldNum << 3) | 0), encodeVarint(value)]);
}

// Prometheus proto: Label { string name = 1; string value = 2; }
function encodeLabel(name, value) {
  return concatBytes([pbStr(1, name), pbStr(2, value)]);
}

// Prometheus proto: Sample { double value = 1; int64 timestamp = 2; }
function encodeSample(value, timestampMs) {
  return concatBytes([pbDouble(1, value), pbVarint(2, timestampMs)]);
}

// Prometheus proto: TimeSeries { repeated Label labels = 1; repeated Sample samples = 2; }
function encodeTimeSeries(labelPairs, value, timestampMs) {
  const labelMsgs = labelPairs.map(([k, v]) => pbLen(1, encodeLabel(k, v)));
  const sampleMsg = pbLen(2, encodeSample(value, timestampMs));
  return concatBytes([...labelMsgs, sampleMsg]);
}

// Prometheus proto: WriteRequest { repeated TimeSeries timeseries = 1; }
function encodeWriteRequest(metrics, timestampMs) {
  return concatBytes(metrics.map(({ name, labels = {}, value }) => {
    const labelPairs = [['__name__', name], ...Object.entries(labels)];
    return pbLen(1, encodeTimeSeries(labelPairs, value, timestampMs));
  }));
}

// ── Snappy block encoding ──────────────────────────────────────────────────────

// Prometheus remote_write uses the Snappy block format (not framing format).
// We emit all data as uncompressed literal commands — valid Snappy output.
//
// Literal tag byte layout (bits 0-1 = 00 = literal type):
//   n <= 60:   1-byte tag = (n-1) << 2
//   n <= 256:  2-byte: 0xF0, n-1
//   n <= 65536: 3-byte: 0xF4, (n-1) LE 2 bytes
function snappyEncode(input) {
  const parts = [encodeVarint(input.length)];
  let offset = 0;
  while (offset < input.length) {
    const n = Math.min(65536, input.length - offset);
    if (n <= 60) {
      parts.push(new Uint8Array([((n - 1) << 2)]));
    } else if (n <= 256) {
      parts.push(new Uint8Array([(60 << 2), n - 1]));
    } else {
      const l = n - 1;
      parts.push(new Uint8Array([(61 << 2), l & 0xFF, l >> 8]));
    }
    parts.push(input.subarray(offset, offset + n));
    offset += n;
  }
  return concatBytes(parts);
}

// ── Public API ─────────────────────────────────────────────────────────────────

export async function writeMetrics(env, metrics) {
  if (!env.GRAFANA_API_KEY) {
    console.warn('GRAFANA_API_KEY not set — skipping metric write');
    return;
  }

  const now   = Date.now();
  const proto = encodeWriteRequest(metrics, now);
  const body  = snappyEncode(proto);

  const credentials = btoa(`${env.GRAFANA_METRICS_USER}:${env.GRAFANA_API_KEY}`);

  const resp = await fetch(env.GRAFANA_METRICS_URL, {
    method: 'POST',
    headers: {
      'Authorization':                     `Basic ${credentials}`,
      'Content-Type':                      'application/x-protobuf',
      'X-Prometheus-Remote-Write-Version': '0.1.0',
    },
    body,
  });

  if (!resp.ok) {
    console.error('Grafana metrics write error:', resp.status, await resp.text());
  }
}
