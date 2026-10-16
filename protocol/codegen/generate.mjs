#!/usr/bin/env node
// Codegen protokol Decky: schema/decky-v1.json -> struct Rust + class Dart.
//
//   node protocol/codegen/generate.mjs
//
// Menangani subset JSON Schema yang dipakai skema Decky: object/properties/
// required, enum string, array, $ref, integer dengan batas, number, string,
// boolean, dan contentEncoding base64 (-> byte).
//
// Keluaran:
//   host/src-tauri/src/proto_gen.rs
//   client/lib/protocol/proto_gen.dart

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const SCHEMA = JSON.parse(readFileSync(resolve(ROOT, "protocol/schema/decky-v1.json"), "utf8"));
const DEFS = SCHEMA.$defs;
const MAP = SCHEMA["x-message-map"];

const BANNER = `// DIBUAT OTOMATIS oleh protocol/codegen/generate.mjs — JANGAN DIEDIT.
// Sumber: protocol/schema/decky-v1.json (protokol v${SCHEMA["x-protocol-version"]})
// Regenerate: node protocol/codegen/generate.mjs
`;

// ── util ────────────────────────────────────────────────────────────────────

const refName = (r) => r.replace("#/$defs/", "");
const snake = (s) => s.replace(/([a-z0-9])([A-Z])/g, "$1_$2").toLowerCase();
const pascal = (s) => s.replace(/(^|[_-])(\w)/g, (_, __, c) => c.toUpperCase());
const camel = (s) => { const p = pascal(s); return p[0].toLowerCase() + p.slice(1); };

/// Nilai enum di kawat boleh apa saja ("image/svg+xml", "monitor.cpu_temp").
/// Identifier Rust dan Dart tidak, jadi semua yang bukan alfanumerik jadi "_".
const identOf = (wire) => String(wire).replace(/[^A-Za-z0-9]+/g, "_").replace(/^_+|_+$/g, "");
const variantRust = (wire) => pascal(identOf(wire)) || "Unknown";
const variantDart = (wire) => camel(identOf(wire)) || "unknown";

/** Telusuri $ref berantai sampai ketemu definisi konkret. */
function deref(node) {
  let n = node, guard = 0;
  while (n && n.$ref && guard++ < 16) n = DEFS[refName(n.$ref)];
  return n;
}

/** Alias murni, mis. "Pong": { "$ref": "#/$defs/Ping" }. */
const isAlias = (node) => !!(node && node.$ref && Object.keys(node).length === 1);

const isBytes = (p) => p.contentEncoding === "base64";

/** Nama tipe Rust/Dart untuk enum string inline di dalam sebuah properti. */
const inlineEnumName = (owner, prop) => pascal(owner) + pascal(prop);

/** Kumpulkan enum string inline supaya bisa di-emit sebagai tipe tersendiri. */
const inlineEnums = new Map(); // nama -> [varian]

function collectInlineEnums() {
  for (const [name, def] of Object.entries(DEFS)) {
    if (isAlias(def) || !def.properties) continue;
    for (const [prop, p] of Object.entries(def.properties)) {
      if (p.enum && p.enum.every((v) => typeof v === "string")) {
        inlineEnums.set(inlineEnumName(name, prop), p.enum);
      }
      if (p.type === "array" && p.items?.enum?.every((v) => typeof v === "string")) {
        inlineEnums.set(inlineEnumName(name, prop) + "Item", p.items.enum);
      }
    }
  }
}

/** Definisi top-level yang murni enum string (Capability, ErrorCode, …). */
const topEnums = Object.entries(DEFS).filter(
  ([, d]) => Array.isArray(d.enum) && d.enum.every((v) => typeof v === "string"),
);

const structDefs = Object.entries(DEFS).filter(
  ([, d]) => !isAlias(d) && !d.enum && (d.type === "object" || d.properties),
);

// ── pemetaan tipe: Rust ─────────────────────────────────────────────────────

function rustInt(p) {
  const lo = p.minimum, hi = p.maximum;
  if (lo === undefined) return "i64";
  if (lo >= 0 && hi !== undefined && hi <= 255) return "u8";
  if (lo >= 0 && hi !== undefined && hi <= 65535) return "u16";
  if (lo >= -32768 && hi !== undefined && hi <= 32767) return "i16";
  if (lo >= 0 && hi !== undefined && hi <= 4294967295) return "u32";
  if (lo >= 0) return "u64";
  return "i64";
}

function rustType(p, owner, prop) {
  if (p.$ref) return refName(p.$ref);
  if (p.enum && p.enum.every((v) => typeof v === "string")) return inlineEnumName(owner, prop);
  switch (p.type) {
    case "string":
      return isBytes(p) ? "Vec<u8>" : "String";
    case "boolean":
      return "bool";
    case "integer":
      return rustInt(p);
    case "number":
      return "f32";
    case "array": {
      const it = p.items ?? {};
      if (it.enum?.every((v) => typeof v === "string")) return `Vec<${inlineEnumName(owner, prop)}Item>`;
      if (it.type === "array") return `Vec<${rustType(it.items ?? {}, owner, prop)}>`.replace("Vec<", "Vec<Vec<") + ">";
      return `Vec<${rustType(it, owner, prop)}>`;
    }
    case "object":
    default:
      return "serde_json::Value";
  }
}

function emitRust() {
  const out = [BANNER, "#![allow(dead_code, clippy::all)]", "", "use serde::{Deserialize, Serialize};", ""];

  for (const [name, def] of topEnums) {
    out.push(`/// ${def.description ?? name}`);
    out.push(`#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]`);
    out.push(`pub enum ${name} {`);
    for (const v of def.enum) out.push(`    #[serde(rename = "${v}")]\n    ${variantRust(v)},`);
    out.push("}", "");
  }

  for (const [name, variants] of inlineEnums) {
    out.push(`#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]`);
    out.push(`pub enum ${name} {`);
    for (const v of variants) out.push(`    #[serde(rename = "${v}")]\n    ${variantRust(v)},`);
    out.push("}", "");
  }

  for (const [name, def] of structDefs) {
    const req = new Set(def.required ?? []);
    if (def.description) out.push(`/// ${def.description}`);
    out.push(`#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]`);
    out.push(`pub struct ${name} {`);
    for (const [prop, p] of Object.entries(def.properties ?? {})) {
      if (prop.startsWith("_")) continue;
      const base = rustType(p, name, prop);
      const ty = req.has(prop) ? base : `Option<${base}>`;
      if (p.description) out.push(`    /// ${p.description}`);
      if (!req.has(prop)) out.push(`    #[serde(default, skip_serializing_if = "Option::is_none")]`);
      if (isBytes(p)) out.push(`    #[serde(with = "serde_bytes")]`);
      out.push(`    pub ${snake(prop)}: ${ty},`);
    }
    out.push("}", "");
  }

  // Enum bertag untuk payload tiap arah.
  const all = { ...MAP.bidirectional, ...MAP.host_to_client, ...MAP.client_to_host };
  for (const [groupName, group] of [
    ["HostMsg", { ...MAP.bidirectional, ...MAP.host_to_client }],
    ["ClientMsg", { ...MAP.bidirectional, ...MAP.client_to_host }],
  ]) {
    out.push(`/// Payload yang sah untuk ${groupName}, di-tag oleh field \`t\` di envelope.`);
    out.push(`#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]`);
    out.push(`#[serde(tag = "t", content = "d")]`);
    out.push(`pub enum ${groupName} {`);
    for (const [t, defName] of Object.entries(group)) {
      out.push(`    #[serde(rename = "${t}")]`);
      out.push(`    ${pascal(t)}(${isAlias(DEFS[defName]) ? refName(DEFS[defName].$ref) : defName}),`);
    }
    out.push("}", "");
  }

  out.push(`pub const PROTOCOL_VERSION: u8 = ${SCHEMA["x-protocol-version"]};`);
  out.push(`pub const DEFAULT_PORT: u16 = ${SCHEMA["x-default-port"]};`);
  out.push(`pub const ALL_MESSAGE_TYPES: [&str; ${Object.keys(all).length}] = [${Object.keys(all).map((t) => `"${t}"`).join(", ")}];`);
  out.push("");

  return out.join("\n");
}

// ── pemetaan tipe: Dart ─────────────────────────────────────────────────────

function dartType(p, owner, prop) {
  if (p.$ref) return refName(p.$ref);
  if (p.enum && p.enum.every((v) => typeof v === "string")) return inlineEnumName(owner, prop);
  switch (p.type) {
    case "string":
      return isBytes(p) ? "Uint8List" : "String";
    case "boolean":
      return "bool";
    case "integer":
      return "int";
    case "number":
      return "double";
    case "array": {
      const it = p.items ?? {};
      if (it.enum?.every((v) => typeof v === "string")) return `List<${inlineEnumName(owner, prop)}Item>`;
      if (it.type === "array") return `List<List<${dartType(it.items ?? {}, owner, prop)}>>`;
      return `List<${dartType(it, owner, prop)}>`;
    }
    default:
      return "Map<String, dynamic>";
  }
}

/** Ekspresi Dart untuk membaca satu properti dari map MessagePack. */
function dartRead(p, owner, prop, req) {
  const key = `m['${prop}']`;
  const t = dartType(p, owner, prop);
  const bang = req ? "" : "?";

  if (p.$ref) {
    const target = deref(p);
    if (Array.isArray(target?.enum)) return req ? `${t}.fromWire(${key} as String)` : `${key} == null ? null : ${t}.fromWire(${key} as String)`;
    return req ? `${t}.fromMap((${key} as Map).cast<String, dynamic>())` : `${key} == null ? null : ${t}.fromMap((${key} as Map).cast<String, dynamic>())`;
  }
  if (p.enum && p.enum.every((v) => typeof v === "string")) {
    return req ? `${t}.fromWire(${key} as String)` : `${key} == null ? null : ${t}.fromWire(${key} as String)`;
  }
  if (p.type === "array") {
    const it = p.items ?? {};
    let inner;
    if (it.$ref) {
      const target = deref(it);
      inner = Array.isArray(target?.enum)
        ? `${refName(it.$ref)}.fromWire(e as String)`
        : `${refName(it.$ref)}.fromMap((e as Map).cast<String, dynamic>())`;
    } else if (it.enum?.every((v) => typeof v === "string")) {
      inner = `${inlineEnumName(owner, prop)}Item.fromWire(e as String)`;
    } else if (it.type === "array") {
      inner = `(e as List).cast<${dartType(it.items ?? {}, owner, prop)}>()`;
    } else if (it.type === "number") {
      inner = `(e as num).toDouble()`;
    } else {
      inner = `e as ${dartType(it, owner, prop)}`;
    }
    const expr = `(${key} as List).map((e) => ${inner}).toList()`;
    return req ? expr : `${key} == null ? null : ${expr}`;
  }
  if (p.type === "number") return req ? `(${key} as num).toDouble()` : `(${key} as num?)?.toDouble()`;
  if (isBytes(p)) return req ? `_bytes(${key})` : `${key} == null ? null : _bytes(${key})`;
  return `${key} as ${t}${bang}`;
}

/** Ekspresi Dart untuk menulis satu properti ke map MessagePack. */
function dartWrite(p, owner, prop, req) {
  const f = camel(prop);
  const opt = req ? "" : "?";
  if (p.$ref) {
    const target = deref(p);
    return Array.isArray(target?.enum) ? `${f}${opt}.wire` : `${f}${opt}.toMap()`;
  }
  if (p.enum && p.enum.every((v) => typeof v === "string")) return `${f}${opt}.wire`;
  if (p.type === "array") {
    const it = p.items ?? {};
    if (it.$ref) {
      const target = deref(it);
      return Array.isArray(target?.enum) ? `${f}${opt}.map((e) => e.wire).toList()` : `${f}${opt}.map((e) => e.toMap()).toList()`;
    }
    if (it.enum?.every((v) => typeof v === "string")) return `${f}${opt}.map((e) => e.wire).toList()`;
  }
  return f;
}

function emitDart() {
  const out = [
    BANNER,
    "// ignore_for_file: constant_identifier_names, non_constant_identifier_names",
    "",
    "import 'dart:typed_data';",
    "",
    "Uint8List _bytes(Object? v) =>",
    "    v is Uint8List ? v : Uint8List.fromList((v as List).cast<int>());",
    "",
  ];

  const emitEnum = (name, variants, doc) => {
    if (doc) out.push(`/// ${doc}`);
    out.push(`enum ${name} {`);
    out.push(variants.map((v) => `  ${variantDart(v)}('${v}')`).join(",\n") + ";");
    out.push("");
    out.push(`  const ${name}(this.wire);`);
    out.push(`  final String wire;`);
    out.push(`  static ${name} fromWire(String w) =>`);
    out.push(`      ${name}.values.firstWhere((e) => e.wire == w);`);
    out.push("}", "");
  };

  for (const [name, def] of topEnums) emitEnum(name, def.enum, def.description);
  for (const [name, variants] of inlineEnums) emitEnum(name, variants);

  for (const [name, def] of structDefs) {
    const req = new Set(def.required ?? []);
    const props = Object.entries(def.properties ?? {}).filter(([k]) => !k.startsWith("_"));

    if (def.description) out.push(`/// ${def.description}`);
    out.push(`class ${name} {`);
    // Dart menolak daftar parameter bernama yang kosong, jadi pesan tanpa
    // field dapat konstruktor polos.
    if (props.length === 0) {
      out.push(`  const ${name}();`, "");
    } else {
      out.push(`  const ${name}({`);
      for (const [prop] of props) out.push(`    ${req.has(prop) ? "required " : ""}this.${camel(prop)},`);
      out.push(`  });`, "");
    }

    for (const [prop, p] of props) {
      if (p.description) out.push(`  /// ${p.description}`);
      out.push(`  final ${dartType(p, name, prop)}${req.has(prop) ? "" : "?"} ${camel(prop)};`);
    }
    out.push("");

    out.push(`  factory ${name}.fromMap(Map<String, dynamic> m) => ${name}(`);
    for (const [prop, p] of props) out.push(`        ${camel(prop)}: ${dartRead(p, name, prop, req.has(prop))},`);
    out.push(`      );`, "");

    out.push(`  Map<String, dynamic> toMap() => <String, dynamic>{`);
    for (const [prop, p] of props) {
      const val = dartWrite(p, name, prop, req.has(prop));
      if (req.has(prop)) out.push(`        '${prop}': ${val},`);
      else out.push(`        if (${camel(prop)} != null) '${prop}': ${val},`);
    }
    out.push(`      };`);
    out.push("}", "");
  }

  const all = { ...MAP.bidirectional, ...MAP.host_to_client, ...MAP.client_to_host };
  out.push("/// Nama tipe pesan, persis seperti di kawat.");
  out.push("abstract final class MsgType {");
  for (const t of Object.keys(all)) out.push(`  static const String ${camel(t)} = '${t}';`);
  out.push("}", "");

  out.push("/// Payload yang dikirim host ke client.");
  out.push(`const Set<String> hostToClientTypes = {${Object.keys({ ...MAP.bidirectional, ...MAP.host_to_client }).map((t) => `'${t}'`).join(", ")}};`);
  out.push("/// Payload yang dikirim client ke host.");
  out.push(`const Set<String> clientToHostTypes = {${Object.keys({ ...MAP.bidirectional, ...MAP.client_to_host }).map((t) => `'${t}'`).join(", ")}};`);
  out.push("");
  out.push(`const int protocolVersion = ${SCHEMA["x-protocol-version"]};`);
  out.push(`const int defaultPort = ${SCHEMA["x-default-port"]};`);
  out.push("");

  return out.join("\n");
}

// ── jalankan ────────────────────────────────────────────────────────────────

collectInlineEnums();

const targets = [
  ["host/src-tauri/src/proto_gen.rs", emitRust()],
  ["client/lib/protocol/proto_gen.dart", emitDart()],
];

for (const [rel, content] of targets) {
  const path = resolve(ROOT, rel);
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, content, "utf8");
  console.log(`tulis ${rel} (${content.split("\n").length} baris)`);
}
