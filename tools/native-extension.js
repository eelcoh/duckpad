// Where the native Excel extension for this host lives.
//
// DuckDB extensions are tied to both an engine version and a platform ABI, so
// the path is computed rather than written down. Both the vendoring script and
// the roundtrip harness need it and must agree: if they drift, the tests pass
// against a different extension than the one Tauri packages.
//
// Everything that loads this does so by explicit path. Nothing here consults
// ~/.duckdb or DuckDB's runtime downloader, which is the same rule the
// application follows and the reason an .xlsx source never needs the network.

const path = require('path');

const VERSION = 'v1.5.5';

const PLATFORMS = {
  'darwin-arm64': 'osx_arm64',
  'darwin-x64': 'osx_amd64',
  'linux-arm64': 'linux_arm64',
  'linux-x64': 'linux_amd64',
  'win32-arm64': 'windows_arm64',
  'win32-x64': 'windows_amd64',
};

const platform = PLATFORMS[`${process.platform}-${process.arch}`] || null;

const extensionPath = platform
  ? path.join(
      __dirname, '..', 'src-tauri', 'resources', 'extensions', VERSION, platform,
      'excel.duckdb_extension'
    )
  : null;

module.exports = { VERSION, PLATFORMS, platform, extensionPath };
