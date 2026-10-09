import { createHash } from "node:crypto";
import { chmod, copyFile, mkdir, mkdtemp, readFile, readdir, realpath, rename, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { deflateRawSync, gzipSync } from "node:zlib";
import { pathToFileURL } from "node:url";

const targets = ["linux-x64", "darwin-x64", "darwin-arm64", "windows-x64", "windows-arm64"];
const sidecars = ["LICENSE", "BUN-LICENSE.md", "THIRD_PARTY_NOTICES.md", "THIRD-PARTY-NOTICES.txt", "VERSION", "UPSTREAM_VERSION", "UPSTREAM_COMMIT"];
function host(): string {
  const target = `${process.platform === "win32" ? "windows" : process.platform}-${process.arch}`;
  if (!targets.includes(target)) throw new Error(`Unsupported native host: ${target}`);
  if (process.platform === "linux" && !process.report.getReport().header.glibcVersionRuntime) throw new Error("Linux releases require glibc");
  return target;
}
const digest = (data: Uint8Array) => createHash("sha256").update(data).digest("hex");
export function isolatedEnv(home: string): Record<string, string> {
  const env: Record<string, string> = { PATH: process.env.PATH ?? "", HOME: home, USERPROFILE: home, TMPDIR: home, TMP: home, TEMP: home, NO_COLOR: "1", XDG_CONFIG_HOME: path.join(home, "config"), XDG_DATA_HOME: path.join(home, "data"), XDG_STATE_HOME: path.join(home, "state"), XDG_CACHE_HOME: path.join(home, "cache"), APPDATA: path.join(home, "appdata"), LOCALAPPDATA: path.join(home, "localappdata") };
  // Windows process startup and native DLL lookup need the OS root, not user credentials.
  for (const key of ["SystemRoot", "WINDIR", "ComSpec", "PATHEXT"]) {
    const entry = Object.entries(process.env).find(([name]) => name.toLowerCase() === key.toLowerCase());
    if (entry?.[1]) env[key] = entry[1];
  }
  return env;
}
async function check(binary: string): Promise<void> {
  const executable = await realpath(binary);
  const workspace = await mkdtemp(path.join(tmpdir(), "omp-zh-check-"));
  try {
    const home = path.join(workspace, "home"), cwd = path.join(workspace, "cwd");
    await mkdir(home); await mkdir(cwd);
    for (const argument of ["--help", "--smoke-test"]) {
      const proc = Bun.spawn([executable, argument], { cwd, env: isolatedEnv(home), stdout: "pipe", stderr: "pipe" });
      const [stdout, stderr, code] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
      if (code !== 0) throw new Error(`${argument} failed (${code}): ${stderr}\n${stdout}`);
      if (argument === "--help" && !/选项|用法/.test(stdout)) throw new Error("Executable help is not Chinese");
      console.log(stdout.trim()); if (stderr) console.error(stderr.trim());
    }
  } finally { await rm(workspace, { recursive: true, force: true }); }
}
async function natives(checkout: string, cache: string, version: string): Promise<void> {
  host();
  checkout = await realpath(checkout);
  const { containsVersionStamp, containsLegacyVersionSentinel } = await import(pathToFileURL(path.join(checkout, "packages/natives/native/version-sentinel.js")).href);
  const filenames = process.arch === "x64" ? ["modern", "baseline"].map(variant => `pi_natives.${process.platform}-x64-${variant}.node`) : [`pi_natives.${process.platform}-arm64.node`];
  const valid = (bytes: Uint8Array) => containsVersionStamp(bytes, version) || containsLegacyVersionSentinel(bytes, version);
  const nativeDir = path.join(checkout, "packages/natives/native");
  let available = 0;
  for (const filename of filenames) {
    const candidate = path.join(cache, filename);
    try {
      if (!(await stat(candidate)).isFile()) continue;
      const bytes = await readFile(candidate);
      if (!valid(bytes)) { console.error(`忽略版本不匹配的缓存：${candidate}`); continue; }
      await writeFile(path.join(nativeDir, filename), bytes); available++;
    } catch (error) { if (error.code !== "ENOENT") throw error; }
  }
  // Upstream accepts any real available x64 variant, including baseline-only npm releases.
  if (available) return;
  const name = `@oh-my-pi/pi-natives-${process.platform}-${process.arch}`;
  const response = await fetch(`https://registry.npmjs.org/${encodeURIComponent(name)}/${version}`);
  if (!response.ok) throw new Error(`Official native metadata unavailable: ${name}@${version} (${response.status})`);
  const metadata = await response.json();
  if (metadata.name !== name || metadata.version !== version) throw new Error("npm native identity/version mismatch");
  const url = new URL(metadata.dist.tarball);
  if (url.protocol !== "https:" || url.hostname !== "registry.npmjs.org") throw new Error("Unexpected npm tarball origin");
  const artifact = await fetch(url);
  if (!artifact.ok) throw new Error(`Native tarball download failed: ${artifact.status}`);
  const bytes = new Uint8Array(await artifact.arrayBuffer());
  const integrity = String(metadata.dist.integrity ?? "").split(/\s+/).find(item => item.startsWith("sha512-"));
  if (!integrity || createHash("sha512").update(bytes).digest("base64") !== integrity.slice(7)) throw new Error("npm native SHA512 integrity mismatch");
  const files = await new Bun.Archive(bytes).files();
  const manifest = files.get("package/package.json");
  if (!manifest) throw new Error("Native package manifest missing");
  const identity = JSON.parse(await manifest.text());
  if (identity.name !== name || identity.version !== version) throw new Error("Native tarball identity/version mismatch");
  for (const filename of filenames) {
    const file = files.get(`package/${filename}`);
    if (!file) continue;
    const addon = new Uint8Array(await file.arrayBuffer());
    if (!valid(addon)) throw new Error(`Native upstream version stamp mismatch: ${filename}`);
    await writeFile(path.join(nativeDir, filename), addon); available++;
  }
  if (!available) throw new Error(`Official package has no expected native addon: ${name}@${version}`);
}
type Member = { name: string; bytes: Buffer; executable: boolean };
function tar(members: Member[], epoch: number): Buffer {
  const parts: Buffer[] = [];
  for (const member of members) {
    const header = Buffer.alloc(512);
    header.write(member.name, 0, 100, "ascii");
    const octal = (offset: number, width: number, value: number) => { const text = value.toString(8); if (text.length >= width) throw new Error("Archive metadata too large"); header.write(text.padStart(width - 1, "0") + "\0", offset, width, "ascii"); };
    octal(100, 8, member.executable ? 0o755 : 0o644); octal(108, 8, 0); octal(116, 8, 0); octal(124, 12, member.bytes.length); octal(136, 12, epoch);
    header.fill(32, 148, 156); header[156] = 48; header.write("ustar\0", 257, 6, "ascii"); header.write("00", 263, 2, "ascii");
    const sum = header.reduce((total, byte) => total + byte, 0); header.write(sum.toString(8).padStart(6, "0") + "\0 ", 148, 8, "ascii");
    parts.push(header, member.bytes, Buffer.alloc((512 - member.bytes.length % 512) % 512));
  }
  parts.push(Buffer.alloc(1024)); return gzipSync(Buffer.concat(parts), { level: 9 });
}
function zip(members: Member[], epoch: number): Buffer {
  // ZIP method 8 (raw deflate): supported by Windows' standard ZIP reader.
  const date = new Date(Math.max(315532800, Math.min(epoch, 4354819199)) * 1000);
  const time = date.getUTCHours() << 11 | date.getUTCMinutes() << 5 | date.getUTCSeconds() >> 1;
  const day = (date.getUTCFullYear() - 1980) << 9 | (date.getUTCMonth() + 1) << 5 | date.getUTCDate();
  const locals: Buffer[] = [], central: Buffer[] = []; let offset = 0;
  const crcTable = new Uint32Array(256);
  for (let index = 0; index < crcTable.length; index++) {
    let crc = index;
    for (let bit = 0; bit < 8; bit++) crc = crc >>> 1 ^ (crc & 1 ? 0xedb88320 : 0);
    crcTable[index] = crc;
  }
  for (const member of members) {
    if (member.bytes.length > 0xffffffff) throw new Error("ZIP64 not supported");
    let crc = 0xffffffff;
    for (const byte of member.bytes) crc = crc >>> 8 ^ crcTable[(crc ^ byte) & 0xff];
    crc = (crc ^ 0xffffffff) >>> 0;
    const name = Buffer.from(member.name), local = Buffer.alloc(30), entry = Buffer.alloc(46);
    const compressed = deflateRawSync(member.bytes, { level: 9 });
    local.writeUInt32LE(0x04034b50); local.writeUInt16LE(20, 4); local.writeUInt16LE(8, 8); local.writeUInt16LE(time, 10); local.writeUInt16LE(day, 12); local.writeUInt32LE(crc, 14); local.writeUInt32LE(compressed.length, 18); local.writeUInt32LE(member.bytes.length, 22); local.writeUInt16LE(name.length, 26);
    entry.writeUInt32LE(0x02014b50); entry.writeUInt16LE(0x0314, 4); entry.writeUInt16LE(20, 6); entry.writeUInt16LE(8, 10); entry.writeUInt16LE(time, 12); entry.writeUInt16LE(day, 14); entry.writeUInt32LE(crc, 16); entry.writeUInt32LE(compressed.length, 20); entry.writeUInt32LE(member.bytes.length, 24); entry.writeUInt16LE(name.length, 28); entry.writeUInt32LE(((0o100000 | (member.executable ? 0o755 : 0o644)) * 65536) >>> 0, 38); entry.writeUInt32LE(offset, 42);
    locals.push(local, name, compressed); central.push(entry, name); offset += local.length + name.length + compressed.length;
  }
  const directory = Buffer.concat(central), end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50); end.writeUInt16LE(members.length, 8); end.writeUInt16LE(members.length, 10); end.writeUInt32LE(directory.length, 12); end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, directory, end]);
}
async function pack(repo: string, binary: string, output: string): Promise<void> {
  const target = host(); repo = await realpath(repo); binary = await realpath(binary);
  const version = (await readFile(path.join(repo, "VERSION"), "utf8")).trim();
  const upstream = (await readFile(path.join(repo, "UPSTREAM_VERSION"), "utf8")).trim();
  const commit = (await readFile(path.join(repo, "UPSTREAM_COMMIT"), "utf8")).trim();
  if (upstream !== "v18.8.6" || !/^v18\.8\.6-zh\.[1-9][0-9]*$/.test(version) || !/^[0-9a-f]{40}$/.test(commit)) throw new Error("Invalid release metadata");
  const epoch = Number(process.env.SOURCE_DATE_EPOCH ?? "0");
  if (!Number.isSafeInteger(epoch) || epoch < 0) throw new Error("SOURCE_DATE_EPOCH must be nonnegative integer seconds");
  await mkdir(output, { recursive: true }); output = await realpath(output);
  const workspace = await mkdtemp(path.join(output, ".omp-zh-package-"));
  try {
    const name = target.startsWith("windows-") ? "omp.exe" : "omp";
    const staged = path.join(workspace, name);
    await copyFile(binary, staged); await chmod(staged, 0o755); await check(staged);
    const members: Member[] = [{ name, bytes: await readFile(staged), executable: true }];
    for (const name of sidecars) { const filename = path.join(repo, name); if (!(await stat(filename)).isFile()) throw new Error(`Not a regular sidecar: ${name}`); const bytes = await readFile(filename); if (!bytes.length) throw new Error(`Empty sidecar: ${name}`); members.push({ name, bytes, executable: false }); }
    members.sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
    const windows = target.startsWith("windows-");
    const asset = `omp-zh-${target}.${windows ? "zip" : "tar.gz"}`;
    const bytes = windows ? zip(members, epoch) : tar(members, epoch);
    const sums = `SHA256SUMS-${target}`;
    await writeFile(path.join(workspace, asset), bytes); await writeFile(path.join(workspace, sums), `${digest(bytes)}  ${asset}\n`);
    await rename(path.join(workspace, asset), path.join(output, asset)); await rename(path.join(workspace, sums), path.join(output, sums));
    console.log(`打包完成：${path.join(output, asset)}\n校验清单：${path.join(output, sums)}`);
  } finally { await rm(workspace, { recursive: true, force: true }); }
}
async function aggregate(directory: string): Promise<void> {
  const expected = targets.map(target => `omp-zh-${target}.${target.startsWith("windows-") ? "zip" : "tar.gz"}`).sort();
  const actual = (await readdir(directory)).filter(name => /\.(tar\.gz|zip)$/.test(name)).sort();
  if (JSON.stringify(expected) !== JSON.stringify(actual)) throw new Error("Release requires exactly all five target archives");
  let sums = "";
  for (const asset of expected) {
    const target = asset.slice(7).replace(/\.(tar\.gz|zip)$/, "");
    const line = `${digest(await readFile(path.join(directory, asset)))}  ${asset}\n`;
    if (await readFile(path.join(directory, `SHA256SUMS-${target}`), "utf8") !== line) throw new Error(`Target checksum mismatch: ${asset}`);
    sums += line;
  }
  await writeFile(path.join(directory, "SHA256SUMS"), sums);
}
if (import.meta.main) {
  const [command, ...args] = process.argv.slice(2);
  switch (command) {
    case "host": console.log(host()); break;
    case "native": await natives(args[0], args[1], args[2]); break;
    case "check": host(); await check(args[0]); break;
    case "package": await pack(args[0], args[1], args[2]); break;
    case "aggregate": await aggregate(args[0]); break;
    default: throw new Error(`Unknown release tools command: ${command}`);
  }
}
