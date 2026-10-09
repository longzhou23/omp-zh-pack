import { createHash } from "node:crypto";
import { chmod, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { isolatedEnv } from "./release-tools";

if (process.platform !== "linux" && process.platform !== "darwin") throw new Error("Use the PowerShell verification helper on Windows");
const version = process.env.OMP_ZH_VERSION ?? "";
const ref = process.env.OMP_ZH_SOURCE_REF ?? "";
if (!/^v18\.8\.6-zh\.[1-9][0-9]*$/.test(version) || !/^[0-9a-f]{40}$/.test(ref)) throw new Error("Published version and immutable source commit are required");
const workspace = await mkdtemp(path.join(tmpdir(), "omp public verification-"));
const hash = async (filename: string) => createHash("sha256").update(await readFile(filename)).digest("hex");
try {
  const home = path.join(workspace, "home"), install = path.join(workspace, "bin with ' quote"), cwd = path.join(workspace, "cwd");
  await mkdir(home); await mkdir(install); await mkdir(cwd);
  const env = { ...isolatedEnv(home), OMP_ZH_VERSION: version, OMP_ZH_INSTALL_DIR: install };
  const url = `https://raw.githubusercontent.com/longzhou23/omp-zh-pack/${ref}/install.sh`;
  const response = await fetch(url);
  if (!response.ok) throw new Error(`Public installer download failed: ${response.status}`);
  const script = path.join(workspace, "install.sh"); await writeFile(script, await response.text());
  async function run(command: string[], overrides: Record<string, string> = {}, expectedFailure = false): Promise<string> {
    const proc = Bun.spawn(command, { cwd, env: { ...env, ...overrides }, stdout: "pipe", stderr: "pipe" });
    const [stdout, stderr, code] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
    console.log(stdout); if (stderr) console.error(stderr);
    if (expectedFailure ? code === 0 : code !== 0) throw new Error(`Unexpected exit ${code}: ${command.join(" ")}`);
    return stdout;
  }
  const binary = path.join(install, "omp");
  // A real existing executable checks first-install backup and recovery; never used as release proof.
  const original = "#!/bin/sh\nprintf 'original executable\\n'\n";
  await writeFile(binary, original); await chmod(binary, 0o755);
  await run(["sh", script]);
  const firstBackups = (await readdir(install)).filter(name => name.startsWith("omp.backup."));
  if (firstBackups.length !== 1 || await readFile(path.join(install, firstBackups[0]), "utf8") !== original) throw new Error("First install did not retain original executable");
  const help = await run([binary, "--help"]); if (!/选项|用法/.test(help)) throw new Error("Public executable help is not Chinese");
  await run([binary, "--smoke-test"]);
  const installedHash = await hash(binary);
  await run(["sh", script]);
  const backups = (await readdir(install)).filter(name => name.startsWith("omp.backup."));
  if (backups.length !== 2 || new Set(backups).size !== 2) throw new Error("Repeat install did not create unique backups");
  const second = backups.find(name => !firstBackups.includes(name))!;
  if (await hash(path.join(install, second)) !== installedHash || await hash(binary) !== installedHash) throw new Error("Repeat backup content mismatch");
  const notices = (await readdir(install)).filter(name => name.startsWith("omp-zh-pack."));
  if (notices.length !== 2) throw new Error("Version/license sidecar directories not retained");
  for (const directory of notices) for (const member of ["LICENSE", "BUN-LICENSE.md", "THIRD_PARTY_NOTICES.md", "THIRD-PARTY-NOTICES.txt", "VERSION", "UPSTREAM_VERSION", "UPSTREAM_COMMIT"]) {
    const contents = await readFile(path.join(install, directory, member), "utf8");
    if (!contents.length || member === "VERSION" && contents.trim() !== version) throw new Error(`Invalid retained sidecar: ${member}`);
  }
  // Real public 404, not a fake successful download; old installation must survive.
  await run(["sh", script], { OMP_ZH_VERSION: `${version}-missing-${ref}` }, true);
  if (await hash(binary) !== installedHash || (await readdir(install)).filter(name => name.startsWith("omp.backup.")).length !== 2) throw new Error("Failed download changed existing installation");
  // Exercise the native platform's documented recovery command, including quoted paths.
  await run(process.platform === "darwin" ? ["mv", "-fh", "--", path.join(install, firstBackups[0]), binary] : ["mv", "-fT", "--", path.join(install, firstBackups[0]), binary]);
  if (await readFile(binary, "utf8") !== original) throw new Error("Backup recovery failed");
  console.log("Public release install, native smoke, repeat backup, failure preservation and recovery passed.");
} finally { await rm(workspace, { recursive: true, force: true }); }
