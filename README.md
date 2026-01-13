# GPU-Accelerated Find

A high-performance `find` replacement that uses GPU acceleration via Metal (macOS) and Vulkan for blazing-fast file searches.

## Features

- **GPU-Accelerated Pattern Matching**: Parallel glob matching on Metal and Vulkan compute shaders
- **SIMD-Optimized CPU**: Vectorized glob matching with 16/32-byte operations
- **Auto-Selection**: Intelligent backend selection based on path count and pattern complexity
- **GNU Compatible**: Drop-in replacement supporting `-name`, `-iname`, `-path`, `-ipath`

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

# Force GPU backend
find --gpu . -name "*.zig"

# Force specific backend
find --metal . -name "*.rs"
find --vulkan . -name "*.go"
find --cpu . -name "*.py"

# Verbose output showing backend selection and timing
find -V . -name "*.js"
```

## Pattern Syntax

| Pattern | Description |
|---------|-------------|
| `*` | Match any sequence of characters |
| `?` | Match any single character |
| `[abc]` | Match any character in set |
| `[a-z]` | Match any character in range |
| `[!abc]` | Match any character NOT in set |

## Options

| Flag | Description |
|------|-------------|
| `-name` | Match basename against pattern |
| `-iname` | Case-insensitive basename match |
| `-path` | Match full path against pattern |
| `-ipath` | Case-insensitive path match |
| `-V, --verbose` | Show timing and backend info |

## Backend Selection

| Flag | Description |
|------|-------------|
| `--auto` | Automatically select optimal backend (default) |
| `--gpu` | Use GPU (Metal on macOS, Vulkan elsewhere) |
| `--cpu` | Force CPU backend |
| `--metal` | Force Metal backend (macOS only) |
| `--vulkan` | Force Vulkan backend |

## Architecture & Optimizations

### CPU Implementation (`src/cpu.zig`)

The CPU backend implements fnmatch-compatible glob matching with SIMD acceleration:

**Glob Pattern Matching**:
- `globMatchSIMD()`: Full glob implementation with `*`, `?`, `[...]` support
- Backtracking algorithm for `*` wildcard handling
- Character class parsing with range support (`[a-z]`) and negation (`[!abc]`)

**SIMD Vector Operations**:
- `Vec16` and `Vec32` types (`@Vector(16, u8)`, `@Vector(32, u8)`)
- `basenameSIMD()`: 32-byte chunked search for last `/` separator
- `toLowerVec16()`: Parallel lowercase conversion using `@select`
- `toLowerSlice()`: 16-byte chunked lowercase for pattern preprocessing

**Character Class Matching**:
- `matchCharClassSIMD()`: Parses `[...]` patterns efficiently
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

| Path Count | GPU Speedup |
|------------|-------------|
| 10K paths | ~3-4x |
| 50K paths | ~3-4x |
| 100K paths | ~4-5x |
| 1M paths | ~5-7x |

| Pattern Type | Speedup |
|--------------|---------|
| Case-insensitive (`-iname`) | **4.2x** |
| Character class (`[a-f]*.log`) | **3.4x** |
| Extension match (`*.txt`) | **3.0x** |
| Path match (`*src/*.c`) | **2.4x** |
| Simple wildcard (`*`) | **1.2x** |

*Results measured on Apple M1 Max with 50K paths.*

## Requirements

- **macOS**: Metal support (built-in), optional MoltenVK for Vulkan
- **Linux**: Vulkan runtime (`libvulkan1`)
- **Build**: Zig 0.15.2+, glslc (Vulkan shader compiler)

## Building from Source

```bash
zig build -Doptimize=ReleaseFast

# Run tests
zig build test      # Unit tests
zig build smoke     # Integration tests
```

## License

Source code: [Unlicense](LICENSE) (public domain)
Binaries: GPL-3.0-or-later
