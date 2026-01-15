# GPU-Accelerated Find

A high-performance `find` replacement that uses GPU acceleration via Metal (macOS) and Vulkan for blazing-fast file searches.

## Features

- **GPU-Accelerated Pattern Matching**: Parallel glob matching on Metal and Vulkan compute shaders
- **SIMD-Optimized CPU**: Vectorized glob matching with 16/32-byte operations
- **Auto-Selection**: Intelligent backend selection based on path count and pattern complexity
- **GNU Compatible**: Full support for size filters, time filters, prune, and common find options

## Installation

Available via Homebrew. See the homebrew-utils repository for installation instructions.

## Usage

```bash
# Basic usage (auto-selects best backend)
find . -name "*.txt"

# Case-insensitive search
find . -iname "*.JPG"

# Full path matching
find . -path "*src/*.c"

# File type filtering
find . -type f -name "*.zig"    # Files only
find . -type d -name "test*"    # Directories only

# Size filtering
find . -size +1M                 # Greater than 1MB
find . -size -100k               # Less than 100KB
find . -size 50c                 # Exactly 50 bytes
find . -size +10M -type f        # Large files only

# Time filtering
find . -mtime -1                 # Modified within last day
find . -mtime +7                 # Modified more than 7 days ago
find . -mtime 0                  # Modified today
find . -atime -1                 # Accessed within last day
find . -ctime +30                # Status changed > 30 days ago

# Prune directories
find . -prune node_modules -name "*.js"
find . -prune ".git" -name "*.c"
find . -prune "build*" -type f

# Depth control
find . -maxdepth 2 -name "*.md"
find . -mindepth 1 -maxdepth 3

# Negation
find . -not -name "*.o"
find . ! -type d

# Empty files/directories
find . -empty -type f
find . -empty -type d

# Force GPU backend
find --gpu . -name "*.zig"

# Force specific backend
find --metal . -name "*.rs"
find --vulkan . -name "*.go"
find --cpu . -name "*.py"

# Verbose output showing backend selection and timing
find -V . -name "*.js"
```

## GNU Feature Compatibility

| Feature | CPU-Optimized | GNU Backend | Metal | Vulkan | Status |
|---------|:-------------:|:-----------:|:-----:|:------:|--------|
| `-name` pattern | ✓ | ✓ | ✓ | ✓ | Native |
| `-iname` case insensitive | ✓ | ✓ | ✓ | ✓ | Native |
| `-path` full path match | ✓ | ✓ | ✓ | ✓ | Native |
| `-ipath` case insensitive | ✓ | ✓ | ✓ | ✓ | Native |
| `-type f/d/l/...` | ✓ | ✓ | ✓ | ✓ | Native |
| `-maxdepth` | ✓ | ✓ | ✓ | ✓ | Native |
| `-mindepth` | ✓ | ✓ | ✓ | ✓ | Native |
| `-print0` | ✓ | ✓ | ✓ | ✓ | Native |
| `-o` (OR patterns) | ✓ | ✓ | — | — | Native (CPU) |
| `-not` / `!` (negation) | ✓ | ✓ | ✓ | ✓ | Native |
| `-empty` | ✓ | ✓ | — | — | Native (CPU) |
| `-size [+-]N[ckMG]` | ✓ | ✓ | — | — | **Native** |
| `-mtime [+-]N` | ✓ | ✓ | — | — | **Native** |
| `-atime [+-]N` | ✓ | ✓ | — | — | **Native** |
| `-ctime [+-]N` | ✓ | ✓ | — | — | **Native** |
| `-prune PATTERN` | ✓ | ✓ | — | — | **Native** |
| `-newer FILE` | — | ✓ | — | — | GNU fallback |
| `-exec` / `-execdir` | — | ✓ | — | — | GNU fallback |
| `-delete` | — | ✓ | — | — | GNU fallback |
| `-regex` | — | ✓ | — | — | GNU fallback |

**Test Coverage**: 36/36 GNU compatibility tests passing

## Pattern Syntax

| Pattern | Description |
|---------|-------------|
| `*` | Match any sequence of characters |
| `?` | Match any single character |
| `[abc]` | Match any character in set |
| `[a-z]` | Match any character in range |
| `[!abc]` | Match any character NOT in set |

## Size Filter Syntax

| Suffix | Meaning |
|--------|---------|
| `c` | Bytes |
| `k` | Kilobytes (1024 bytes) |
| `M` | Megabytes (1024 KB) |
| `G` | Gigabytes (1024 MB) |
| (none) | 512-byte blocks |

| Prefix | Meaning |
|--------|---------|
| `+` | Greater than |
| `-` | Less than |
| (none) | Exactly |

## Time Filter Syntax

| Prefix | Meaning |
|--------|---------|
| `+N` | More than N days ago |
| `-N` | Within the last N days |
| `N` | Exactly N days ago |

## Options

| Flag | Description |
|------|-------------|
| `-name PATTERN` | Match basename against pattern |
| `-iname PATTERN` | Case-insensitive basename match |
| `-path PATTERN` | Match full path against pattern |
| `-ipath PATTERN` | Case-insensitive path match |
| `-type TYPE` | File type (f=file, d=dir, l=link, etc.) |
| `-maxdepth N` | Max directory depth |
| `-mindepth N` | Min directory depth |
| `-size [+-]N[ckMG]` | Filter by file size |
| `-mtime [+-]N` | Filter by modification time (days) |
| `-atime [+-]N` | Filter by access time (days) |
| `-ctime [+-]N` | Filter by status change time (days) |
| `-prune PATTERN` | Skip directories matching pattern |
| `-empty` | Match empty files/directories |
| `-not`, `!` | Negate following test |
| `-o` | OR multiple patterns |
| `-print0` | Null-terminated output |
| `-V, --verbose` | Show timing and backend info |

## Backend Selection

| Flag | Description |
|------|-------------|
| `--auto` | Automatically select optimal backend (default) |
| `--gpu` | Use GPU (Metal on macOS, Vulkan elsewhere) |
| `--cpu` | Force CPU backend |
| `--gnu` | Force GNU find backend |
| `--metal` | Force Metal backend (macOS only) |
| `--vulkan` | Force Vulkan backend |

## Architecture & Optimizations

### CPU Implementation (`src/main.zig`)

The CPU backend implements fnmatch-compatible glob matching with SIMD acceleration:

**Glob Pattern Matching**:
- `matchGlob()`: Full glob implementation with `*`, `?`, `[...]` support
- Backtracking algorithm for `*` wildcard handling
- Character class parsing with range support (`[a-z]`) and negation (`[!abc]`)

**SIMD Vector Operations**:
- `Vec16` and `Vec32` types (`@Vector(16, u8)`, `@Vector(32, u8)`)
- `basenameSIMD()`: 32-byte chunked search for last `/` separator
- `toLowerVec16()`: Parallel lowercase conversion using `@select`
- `toLowerSlice()`: 16-byte chunked lowercase for pattern preprocessing

**Size Filter**:
- `SizeFilter` struct with `bytes`, `comparison` (exact/greater/less)
- `parseSizeArg()`: Parses `[+-]N[ckMG]` format
- Applied after stat in `walkDirectory()`

**Time Filter**:
- `TimeFilter` struct with `days`, `comparison`, `time_type`
- Handles `mtime`, `atime`, `ctime` with proper macOS i128 nanoseconds handling
- Comparison: newer (`-N`), older (`+N`), exact (`N`)

**Prune**:
- `prune_pattern` in `FindOptions`
- Checked at directory entry, skips entire subtree on match
- Supports glob patterns (`build*`, `.git`)

**Character Class Matching**:
- `matchCharClass()`: Parses `[...]` patterns efficiently
- Handles ranges, negation, and literal `]` as first character
- Returns match result and consumed bytes for pattern advancement

**Leading Period Rule**:
- `match_period` option prevents `*` from matching leading `.`
- Explicit `.` in pattern required to match hidden files

### GPU Implementation

**Metal Shader (`src/shaders/match.metal`)**:

- **Parallel Path Matching**: Each thread handles one path from the batch
- **uchar4 SIMD**: 4-byte vectorized character comparisons
- **Glob State Machine**: Full `*`, `?`, `[...]` pattern support on GPU
- **Basename Extraction**: `find_basename_start()` with vectorized `/` search

**Vulkan Shader (`src/shaders/match.comp`)**:

- **Batch Processing**: One thread per path in the input batch
- **uvec4 SIMD**: 16-byte vectorized comparison via `match_uvec4()`
- **Workgroup Size**: 256 threads (`local_size_x = 256`)
- **Shared Pattern Data**: Pattern loaded once, applied to many paths

### Pattern Matching Algorithm

```
globMatchImpl(pattern, name):
  - pi = 0, ni = 0 (pattern and name indices)
  - star_pi = null (last * position for backtracking)

  while ni < name.len:
    if pattern[pi] == '*':
      star_pi = pi     // Save backtrack point
      star_ni = ni
      pi++
    elif pattern[pi] == '?':
      pi++, ni++       // Match any single char
    elif pattern[pi] == '[':
      match character class
    elif chars_match(pattern[pi], name[ni]):
      pi++, ni++
    elif star_pi != null:
      pi = star_pi + 1  // Backtrack
      star_ni++
      ni = star_ni
    else:
      return false

  skip trailing * in pattern
  return pi == pattern.len
```

### Auto-Selection

The `e_jerk_gpu` library scores based on:

- **Batch Size**: GPU preferred for 10K+ paths
- **Pattern Complexity**: Character classes and multiple wildcards favor GPU
- **Hardware Tier**: Adjusts thresholds based on GPU performance

## Performance

| Path Count | CPU | GPU | Speedup |
|------------|-----|-----|---------|
| 10K paths | 4.3M paths/s | 13.6M paths/s | **3.2x** |
| 50K paths | 4.7M paths/s | 16.7M paths/s | **3.6x** |
| Case-insensitive | 3.5M paths/s | 15.0M paths/s | **4.3x** |
| Character class | 4.3M paths/s | 15.0M paths/s | **3.5x** |
| Complex pattern | 10.7M paths/s | 15.0M paths/s | **1.4x** |

*Results measured on Apple M1 Max.*

## Requirements

- **macOS**: Metal support (built-in), optional MoltenVK for Vulkan
- **Linux**: Vulkan runtime (`libvulkan1`)
- **Build**: Zig 0.15.2+, glslc (Vulkan shader compiler)

## Building from Source

```bash
zig build -Doptimize=ReleaseFast

# Run tests
zig build test      # Unit tests
zig build smoke     # Integration tests (GPU verification)
bash gnu-tests.sh   # GNU compatibility tests (36 tests)
```

## Recent Changes

- **Size Filter**: Native `-size [+-]N[ckMG]` support for filtering by file size
- **Time Filters**: Native `-mtime`, `-atime`, `-ctime` with `[+-]N` syntax
- **Prune**: Native `-prune PATTERN` to skip directories matching glob patterns
- **macOS Compatibility**: Proper handling of macOS i128 nanosecond timestamps
- **Test Coverage**: 36 GNU compatibility tests passing

## License

Source code: [Unlicense](LICENSE) (public domain)
Binaries: GPL-3.0-or-later
