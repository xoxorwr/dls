import * as vscode from 'vscode';
import * as fs from 'fs';
import * as path from 'path';
import * as http from 'http';
import * as https from 'https';
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

// Downloads + extracts `asset` into a fresh, throwaway staging directory
// (never directly onto `bin`) and returns the path to the extracted binary
// there. Keeping the download/extract off the live binary means a failed or
// partial fetch never corrupts what's currently installed.
async function fetchToStaging(dir: string, asset: string): Promise<{ staging: string; extracted: string }> {
  const staging = fs.mkdtempSync(path.join(dir, 'tmp-'));
  const archive = path.join(staging, asset);
  const url = `https://github.com/${REPO}/releases/download/${TAG}/${asset}`;
  await download(url, archive);
  await extract(archive, staging);
  const extracted = path.join(staging, binaryName());
  if (process.platform !== 'win32') {
    fs.chmodSync(extracted, 0o755);
  }
  return { staging, extracted };
}

// Swaps the freshly extracted binary into place. On Windows this fails with
// EBUSY/EPERM if `bin` is still open by a running dls process (its own file,
// or another VS Code window's) - Windows won't let you replace an in-use
// executable, unlike POSIX where a running process just keeps its old inode.
// Returns false (instead of throwing) for that specific case so the caller
// can fall back to the still-installed binary and retry on a later launch.
function installBinary(extracted: string, bin: string): boolean {
  try {
    fs.renameSync(extracted, bin);
    return true;
  } catch (err) {
    const code = (err as NodeJS.ErrnoException).code;
    if (code === 'EBUSY' || code === 'EPERM' || code === 'EACCES') {
      return false;
    }
    throw err;
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
  const bin = path.join(dir, binaryName());
  const stamp = path.join(dir, 'dls.sha256');
  fs.mkdirSync(dir, { recursive: true });
  const have = fs.existsSync(bin);

  // `SHA256SUMS` is a few hundred bytes; a cheap freshness check per
  // activation. Offline or rate-limited? fall back to the cached binary.
  let expected: string | undefined;
  if (config.get<boolean>('autoUpdate', true)) {
    expected = await fetchExpectedSha(asset).catch(() => undefined);
    if (have) {
      if (!expected) {
        return bin;
      }
      const current = fs.existsSync(stamp) ? fs.readFileSync(stamp, 'utf8').trim() : '';
      if (current === expected) {
        return bin;
      }
    }
  } else if (have) {
    return bin;
  }

  return vscode.window.withProgress(
    {
      location: vscode.ProgressLocation.Notification,
      title: `Downloading dls (${asset})`,
    },
    async () => {
      const { staging, extracted } = await fetchToStaging(dir, asset);
      try {
        const installed = installBinary(extracted, bin);
        if (!installed) {
          void vscode.window.showInformationMessage(
            'dls: a new nightly build is available, but the installed server binary is ' +
              'still in use (likely by another open window) and can\'t be replaced. It ' +
              'will be installed automatically the next time you launch VS Code with no ' +
              'dls server running.',
          );
          fs.rmSync(stamp, { force: true });
          return bin;
        }
        if (expected) {
          fs.writeFileSync(stamp, expected + '\n', 'utf8');
        } else {
          fs.rmSync(stamp, { force: true });
        }
        return bin;
      } finally {
        fs.rmSync(staging, { recursive: true, force: true });
      }
    },
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
