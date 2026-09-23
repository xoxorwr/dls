import * as vscode from 'vscode';
import * as fs from 'fs';
import * as path from 'path';
import * as http from 'http';
import * as https from 'https';
import * as crypto from 'crypto';
import { execFile } from 'child_process';

const REPO = 'xoxorwr/dls';
const TAG = 'nightly';

function assetName(): string | undefined {
  if (process.platform === 'linux' && process.arch === 'x64') {
    return 'dls-linux-x64.tar.gz';
  }
  if (process.platform === 'darwin' && process.arch === 'arm64') {
    return 'dls-darwin-arm64.tar.gz';
  }
  if (process.platform === 'darwin' && process.arch === 'x64') {
    return 'dls-darwin-x64.tar.gz';
  }
  if (process.platform === 'win32' && process.arch === 'x64') {
    return 'dls-win-x64.zip';
  }
  return undefined;
}

function binaryName(): string {
  return process.platform === 'win32' ? 'dls.exe' : 'dls';
}

// Binaries live at a path keyed by content hash (dls-<sha256>[.exe]) rather
// than a fixed name. A running server keeps its file open for the lifetime
// of the process; on Windows that means the file can't be overwritten or
// deleted while in use (POSIX allows it - the running process just keeps
// the old inode - which is why this only ever bit Windows users). Keying by
// hash means an update always lands at a brand-new path, so installing it
// never touches whatever the currently-running server has open.
function binPath(dir: string, sha: string): string {
  const ext = process.platform === 'win32' ? '.exe' : '';
  return path.join(dir, `dls-${sha}${ext}`);
}

// Best-effort GC of old versioned binaries. A binary still in use by a
// running server (e.g. from another open window) can't be removed on
// Windows; just leave it for a future call once that server has exited.
function cleanupOldBinaries(dir: string, keepSha: string): void {
  const keep = path.basename(binPath(dir, keepSha));
  let entries: string[];
  try {
    entries = fs.readdirSync(dir);
  } catch {
    return;
  }
  for (const entry of entries) {
    if (entry === keep || !/^dls-[0-9a-f]{64}(\.exe)?$/.test(entry)) {
      continue;
    }
    try {
      fs.rmSync(path.join(dir, entry), { force: true });
    } catch {
      // still in use elsewhere; try again next time.
    }
  }
}

function sha256File(file: string): string {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

// Downloads + extracts `asset` into a fresh staging directory, then moves
// the binary into its content-addressed final path and returns it.
async function installServer(dir: string, asset: string): Promise<string> {
  const staging = fs.mkdtempSync(path.join(dir, 'tmp-'));
  try {
    const archive = path.join(staging, asset);
    const url = `https://github.com/${REPO}/releases/download/${TAG}/${asset}`;
    await download(url, archive);
    await extract(archive, staging);

    const extracted = path.join(staging, binaryName());
    const sha = sha256File(extracted);
    const target = binPath(dir, sha);
    if (!fs.existsSync(target)) {
      if (process.platform !== 'win32') {
        fs.chmodSync(extracted, 0o755);
      }
      fs.renameSync(extracted, target);
    }

    const currentFile = path.join(dir, 'dls.current');
    fs.writeFileSync(currentFile, sha + '\n', 'utf8');
    cleanupOldBinaries(dir, sha);
    return target;
  } finally {
    fs.rmSync(staging, { recursive: true, force: true });
  }
}

export async function ensureServer(
  context: vscode.ExtensionContext,
  config: vscode.WorkspaceConfiguration,
): Promise<string> {
  const configured = (config.get<string>('serverPath', '') || '').trim();
  if (configured) {
    return configured;
  }

  const asset = assetName();
  if (!asset) {
    throw new Error(
      `no prebuilt dls for ${process.platform}/${process.arch}; ` +
        `set "dls.serverPath" to a local build.`,
    );
  }

  const dir = context.globalStorageUri.fsPath;
  fs.mkdirSync(dir, { recursive: true });

  const currentFile = path.join(dir, 'dls.current');
  const currentSha = fs.existsSync(currentFile)
    ? fs.readFileSync(currentFile, 'utf8').trim()
    : undefined;
  const currentBin = currentSha ? binPath(dir, currentSha) : undefined;
  const haveCurrent = !!currentBin && fs.existsSync(currentBin);

  if (!config.get<boolean>('autoUpdate', true)) {
    if (haveCurrent) {
      return currentBin!;
    }
    return vscode.window.withProgress(
      { location: vscode.ProgressLocation.Notification, title: `Downloading dls (${asset})` },
      () => installServer(dir, asset),
    );
  }

  // `SHA256SUMS` is a few hundred bytes; a cheap freshness check per
  // activation. Offline or rate-limited? fall back to the cached binary.
  const expected = await fetchExpectedSha(asset).catch(() => undefined);
  if (expected) {
    if (haveCurrent && expected === currentSha) {
      cleanupOldBinaries(dir, expected);
      return currentBin!;
    }
    const target = binPath(dir, expected);
    if (fs.existsSync(target)) {
      fs.writeFileSync(currentFile, expected + '\n', 'utf8');
      cleanupOldBinaries(dir, expected);
      return target;
    }
  } else if (haveCurrent) {
    return currentBin!;
  }

  return vscode.window.withProgress(
    { location: vscode.ProgressLocation.Notification, title: `Downloading dls (${asset})` },
    () => installServer(dir, asset),
  );
}

// Hash of our nightly archive from the release's SHA256SUMS, if present.
async function fetchExpectedSha(asset: string): Promise<string | undefined> {
  const url = `https://github.com/${REPO}/releases/download/${TAG}/SHA256SUMS`;
  const body = await fetchText(url);
  for (const line of body.split('\n')) {
    const m = line.trim().split(/\s+/);
    if (m.length >= 2 && m[1] === asset) {
      return m[0].toLowerCase();
    }
  }
  return undefined;
}

function httpGet(url: string): Promise<http.IncomingMessage> {
  return new Promise((resolve, reject) => {
    const follow = (target: string, redirects: number): void => {
      if (redirects > 5) {
        reject(new Error('too many redirects'));
        return;
      }
      https
        .get(target, (res) => {
          const status = res.statusCode ?? 0;
          if (status >= 300 && status < 400 && res.headers.location) {
            res.resume();
            follow(res.headers.location, redirects + 1);
            return;
          }
          if (status !== 200) {
            res.resume();
            reject(new Error(`HTTP ${status} for ${target}`));
            return;
          }
          resolve(res);
        })
        .on('error', reject);
    };
    follow(url, 0);
  });
}

function download(url: string, dest: string): Promise<void> {
  return httpGet(url).then(
    (res) =>
      new Promise<void>((resolve, reject) => {
        const out = fs.createWriteStream(dest);
        res.pipe(out);
        out.on('finish', () => out.close(() => resolve()));
        out.on('error', reject);
      }),
  );
}

function fetchText(url: string): Promise<string> {
  return httpGet(url).then(
    (res) =>
      new Promise<string>((resolve, reject) => {
        const chunks: Buffer[] = [];
        res.on('data', (c: Buffer) => chunks.push(c));
        res.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
        res.on('error', reject);
      }),
  );
}

function extract(archive: string, dest: string): Promise<void> {
  const [cmd, args] =
    process.platform === 'win32'
      ? [
          'powershell',
          [
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            `Expand-Archive -Force -LiteralPath '${archive}' -DestinationPath '${dest}'`,
          ],
        ]
      : ['tar', ['-xzf', archive, '-C', dest]];
  return new Promise((resolve, reject) => {
    execFile(cmd, args, (err) => (err ? reject(err) : resolve()));
  });
}
