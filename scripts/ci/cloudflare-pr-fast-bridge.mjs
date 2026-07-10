import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const pnpmVersion = "11.5.2";
const rustToolchain = "1.96.0";
const powershellVersion = "7.6.3";
const outputDirectory = join(process.cwd(), "dist", "cloudflare-pr-fast");
const powershellCacheDirectory = join(process.cwd(), ".cache", "powershell");
const powershellInstallDirectory = join(powershellCacheDirectory, powershellVersion);
const powershellArchivePath = join(
  powershellCacheDirectory,
  `powershell-${powershellVersion}-linux-x64.tar.gz`,
);
process.env.COREPACK_HOME ??= join(process.cwd(), ".cache", "corepack");

function run(command) {
  console.log(`$ ${command}`);
  const result = spawnSync(command, {
    cwd: process.cwd(),
    env: process.env,
    shell: true,
    stdio: "inherit",
  });

  if (result.error) {
    throw result.error;
  }

  if (result.status !== 0) {
    throw new Error(`Command failed with exit code ${result.status}: ${command}`);
  }
}

function commandExists(command) {
  const probe = process.platform === "win32"
    ? `where ${command}`
    : `command -v ${command}`;
  const result = spawnSync(probe, {
    cwd: process.cwd(),
    env: process.env,
    shell: true,
    stdio: "ignore",
  });

  return result.status === 0;
}

function installRustupOnUnix() {
  if (process.platform === "win32") {
    throw new Error("rustup is required on Windows before running the Cloudflare PR-fast bridge.");
  }

  run("curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain none");
  process.env.PATH = `${process.env.HOME}/.cargo/bin:${process.env.PATH}`;
}

function installPowershellOnUnix() {
  if (process.platform === "win32") {
    throw new Error("pwsh is required on Windows before running the Cloudflare PR-fast bridge.");
  }

  const powershellExecutable = join(powershellInstallDirectory, "pwsh");
  if (!existsSync(powershellExecutable)) {
    mkdirSync(powershellInstallDirectory, { recursive: true });
    run(
      `curl -L -o ${shellQuote(powershellArchivePath)} https://github.com/PowerShell/PowerShell/releases/download/v${powershellVersion}/powershell-${powershellVersion}-linux-x64.tar.gz`,
    );
    run(`tar -xzf ${shellQuote(powershellArchivePath)} -C ${shellQuote(powershellInstallDirectory)}`);
    run(`chmod +x ${shellQuote(powershellExecutable)}`);
  }

  process.env.PATH = `${powershellInstallDirectory}:${process.env.PATH}`;
}

function preparePowershell() {
  if (commandExists("pwsh")) {
    return;
  }

  installPowershellOnUnix();

  if (!commandExists("pwsh")) {
    throw new Error("pwsh is required before running the state-engine Beta performance gate.");
  }
}

function prepareRustToolchain() {
  if (!commandExists("rustup")) {
    installRustupOnUnix();
  }

  run(`rustup toolchain install ${rustToolchain} --profile minimal`);
  run(`rustup component add rustfmt --toolchain ${rustToolchain}`);
}

function shellQuote(value) {
  return `'${String(value).replaceAll("'", "'\"'\"'")}'`;
}

run("node --version");
run(`corepack prepare pnpm@${pnpmVersion} --activate`);
prepareRustToolchain();
preparePowershell();

run("corepack pnpm install --frozen-lockfile");
run("corepack pnpm -r check");
run("corepack pnpm -r test");
run("corepack pnpm release:test-state-engine-beta-performance:win32-x64");
run(`cargo +${rustToolchain} fmt --all -- --check`);
run(`cargo +${rustToolchain} test --workspace --lib`);
run(`cargo +${rustToolchain} test -p subversionr-protocol --test protocol_contract`);

mkdirSync(outputDirectory, { recursive: true });
writeFileSync(
  join(outputDirectory, "index.html"),
  "SubversionR PR Fast Cloudflare bridge\n",
  "utf8",
);
