# mouser — Find & Delete Dependency Directories

Lightning-fast disk space reclamation. Scans for and removes `node_modules`, `.venv`, `venv`, `target/`, `__pycache__`, and other heavy dependency/build directories.

Written in Zig. Single binary. Zero dependencies.

## Features

### Scanning & Detection

- **Built-in targets**: `.venv`, `venv`, `node_modules`, `.next`, `.nuxt`, `__pycache__`, `.git` (optional), `target/` (Rust)
- **Custom targets**: Add your own directories via `--target foo,bar,baz`
- **Rust detection**: Finds `target/` only if `Cargo.toml` exists in parent directory (avoids false positives)
- **Smart skipping**: Ignores Windows system dirs (`$RECYCLE.BIN`, `System Volume Information`), avoiding errors
- **Stack-based recursion**: No recursion limit—scans arbitrarily deep directory trees
- **Parallel size calculation**: Multi-threaded disk size measurement (4 threads default, configurable)

### Filtering

- **By type**: `--filter python` (venv, __pycache__), `--filter node` (node_modules, .next, .nuxt), `--filter rust` (target/), `--filter all` (default)
- **By size**: `--min-size 50MB` or `--min-size 1.5GiB` — only show dirs larger than threshold
- **By age**: `--older-than 30` — only dirs not touched in N days
- **By depth**: `--depth 3` — limit scan depth

### Output Modes

- **Colored table** (default): Human-readable table with syntax highlighting per category
- **JSON**: Machine-readable structured output (`--json`)
- **CSV/JSON export**: Save results to file for spreadsheet or pipeline use (`--export results.csv`)
- **No color**: `--no-color` for piping or terminals that don't support ANSI

### Sorting

- Default: by directory name
- `--sort-size`: largest first
- `--sort-age`: oldest first (useful with `--older-than`)

### Deletion

- **Dry run**: `--dry-run` — show what *would* be deleted, don't touch anything
- **Batch delete**: `--delete` — delete all matching directories with confirmation prompt
- **Interactive picker**: `--interactive` — numbered list, pick specific directories to delete (supports ranges: `1,3,5-10` or `all`)

### Miscellaneous

- `--no-size`: Skip size calculation (much faster, useful for just listing)
- `--threads N`: Control parallelism for size measurement
- `--help`: Show all options

## Usage

### Scanning Behavior

**`mouser` recursively scans ALL subdirectories** starting from the specified path (or current directory). It digs through the entire directory tree looking for target directories (node_modules, .venv, target/, etc.).

Examples:
- `mouser` — scans current dir and all subdirs recursively
- `mouser ~/projects` — scans ~/projects and all subdirs below it
- `mouser --depth 2` — scans current dir, down to 2 levels deep (faster, top-level only)
- `mouser --no-size` — recursive scan, but skip size calculation (much faster)

### Usage Examples

### List all dependencies in current directory
```bash
mouser
```

### Find Python venvs only, sorted by size
```bash
mouser --filter python --sort-size
```

### Find everything older than 90 days, export to CSV
```bash
mouser --older-than 90 --export report.csv
```

### Find directories larger than 500MB
```bash
mouser --min-size 500MB
```

### Dry run: see what would be deleted from home directory
```bash
mouser ~ --dry-run
```

### Interactive mode: pick specific dirs to delete
```bash
mouser --interactive
# Output:
#   1  [1.2 GiB]  node_modules
#   2  [856 MiB]  .venv
#   3  [512 MiB]  target
#
# Select: 1,3
```

### Delete all node_modules with confirmation
```bash
mouser --filter node --delete
```

### Scan to depth 2 only (fast, top-level only)
```bash
mouser --depth 2
```

### Add custom targets (e.g., `__temp__`, `build/`)
```bash
mouser --target __temp__,build --sort-size
```

### Find Rust projects not built in 30 days and delete them
```bash
mouser --filter rust --older-than 30 --delete
```

### Output as JSON for parsing
```bash
mouser --json | jq '.targets[] | select(.size_bytes > 1000000000)'
```

## Output Examples

### Default (colored table)
```
  Type           Size  Age(d)  Path
  ────────────────────────────────────────────────────────────────
  node_modules   1.2G      42  ~/projects/app1/node_modules
  node_modules   856M      15  ~/projects/app2/node_modules
  python_venv    512M       7  ~/data-project/.venv
  rust_target    1.5G      90  ~/hobby-code/target
```

### JSON output
```json
{
  "total_bytes": 4294967296,
  "entries": [
    {
      "path": "/home/user/projects/app1/node_modules",
      "kind": "node_modules",
      "size_bytes": 1288490189,
      "modified_timestamp": 1234567890
    }
  ],
  "summary": {
    "node_modules": {
      "count": 2,
      "total_bytes": 2147483648
    }
  }
}
```

## Building

### Prerequisites

- **Zig 0.15 or later** — [Download](https://ziglang.org/download/)
- Git (for cloning)
- ~500MB disk space (for build cache)

### Clone & Setup

```bash
git clone https://github.com/26holiday/package-mouser
cd package-mouser
```

### Development Build

Fast, with debug symbols (slower runtime, smaller binary):

```bash
zig build
./zig-out/bin/mouser --help
```

Or build & run together:

```bash
zig build run -- --help
```

### Release Build (Optimized)

Fast runtime, fully optimized (slower compile):

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/mouser
```

For maximum optimization (very slow compile):

```bash
zig build -Doptimize=ReleaseSmall
```

### Clean Build

Remove cache and rebuild from scratch:

```bash
rm -rf zig-out .zig-cache
zig build -Doptimize=ReleaseFast
```

### Run Tests (if added later)

```bash
zig build test
```

### Pre-built Binaries

Download pre-compiled binaries from [Releases](https://github.com/26holiday/package-mouser/releases)

### Add to System PATH (Optional)

Make `mouser` available from any directory:

**Windows (PowerShell as Admin):**
```powershell
$project = "C:\Users\Shahzaib\Desktop\package-mouser\zig-out\bin"
[Environment]::SetEnvironmentVariable("PATH", $env:PATH + ";$project", "User")
# Restart terminal
mouser --help
```

**macOS/Linux:**
```bash
export PATH="$PATH:$HOME/path/to/package-mouser/zig-out/bin"
# Add above line to ~/.bashrc or ~/.zshrc for persistence
mouser --help
```

**Alternative: Copy binary to PATH**
```bash
# Windows
copy zig-out\bin\mouser.exe C:\Windows\System32\

# macOS/Linux
sudo cp zig-out/bin/mouser /usr/local/bin/
```

## Performance

- **Scan time**: ~1-2 seconds for typical home directory (scales with depth)
- **Size calculation**: Parallelized across 4 threads (configurable), typically fastest bottleneck
- **Memory**: Minimal (all results streamed, not loaded)

Use `--no-size` for much faster scans when you only need to list directories.

## Compatibility

- **OS**: Windows, macOS, Linux
- **Zig**: 0.15+

## Exit Codes

- `0`: Success
- `1`: Error (missing directory, permission denied, etc.)

## Notes

- **Safe by default**: Requires explicit `--delete` or `--interactive` to modify disk
- **Windows support**: Full color support, proper path handling, UNC paths supported
- **Permission errors**: Skipped gracefully, reported in summary
- **Rust detection**: Only treats `target/` as Rust-specific if a `Cargo.toml` file exists in the parent directory

## License

MIT
