# dls (VS Code)

Minimal VS Code client for the `dls` language server.

## Install

Install the `dls.vsix` from the
[nightly release](https://github.com/xoxorwr/dls/releases/tag/nightly)
(`Extensions: Install from VSIX…`).

On first activation the extension downloads the `dls` binary for your
platform (Linux x64, macOS arm64/x64, Windows x64) into the extension's
global storage.
Set `dls.serverPath` to use a local build instead.

The binary is refreshed automatically: on each activation the extension
fetches the nightly release's `SHA256SUMS` (a few hundred bytes) and
re-downloads only when the hash changed. If the release can't be reached
it falls back to the cached binary. Disable with `dls.autoUpdate`
= `false`.

> On Windows the server is a `.exe`; the extension picks
> `dls-win-x64.zip` automatically.

## Settings

| Setting | Meaning |
|---|---|
| `dls.serverPath` | Path to the `dls` binary; empty = download nightly |
| `dls.autoUpdate` | Re-download the binary when the nightly changed (default true) |
| `dls.autoCloseBrackets` | Auto-close brackets/quotes while typing (default true) |

Comment toggling (`Ctrl+/`, `Shift+Alt+A`) and bracket pairs come from the
bundled `language-configuration.json`.

Project defaults belong in `dls.json` at the workspace root; it is read by
the server and overrides these per-run.

## Commands

- **dls: Create dls.json** — writes a starter `dls.json` at the
  workspace root (seeding `importPaths` from `src/`, `source/`
  when they exist, plus any `dls.*` settings) and restarts the server so
  it takes effect. If the file already exists it is just opened.

Opening a `.d` file in a workspace that has no `dls.json` offers to create
one (dismissible per session, or permanently with **Don't show again**).

## Build

```sh
npm install
npm run compile
npm run package   # -> dls.vsix
```
