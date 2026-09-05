// Vendor the signed native Excel extension matching the DuckDB Rust crate.
//
// DuckDB extensions are tied to both an engine version and a platform ABI.
// CI runs this on each native build host, then Tauri packages only that host's
// extension. The application loads the explicit resource path, so it never
// falls back to DuckDB's runtime downloader or a file in ~/.duckdb.

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const VERSION = 'v1.5.5';
const PLATFORMS = {
  'darwin-arm64': 'osx_arm64',
  'darwin-x64': 'osx_amd64',
  'linux-arm64': 'linux_arm64',
  'linux-x64': 'linux_amd64',
  'win32-arm64': 'windows_arm64',
  'win32-x64': 'windows_amd64',
};

const platform = PLATFORMS[`${process.platform}-${process.arch}`];
if (!platform) {
  console.error(`native DuckDB Excel is not configured for ${process.platform}-${process.arch}`);
  process.exit(1);
}

const destination = path.join(
  __dirname, '..', 'src-tauri', 'resources', 'extensions', VERSION, platform,
  'excel.duckdb_extension'
);

if (process.argv.includes('--check')) {
  process.exit(fs.existsSync(destination) ? 0 : 1);
}

async function main() {
  const url = `https://extensions.duckdb.org/${VERSION}/${platform}/excel.duckdb_extension.gz`;
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${response.status} ${response.statusText} for ${url}`);
  const compressed = Buffer.from(await response.arrayBuffer());
  const extension = zlib.gunzipSync(compressed);
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.writeFileSync(destination, extension);
  process.stdout.write(`  native ${VERSION}/${platform}/excel.duckdb_extension (${Math.round(extension.length / 1024)}k)\n`);
}

main().catch((error) => {
  console.error(`native Excel vendoring failed: ${error.message}`);
  process.exit(1);
});
