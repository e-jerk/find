#include <metal_stdlib>
#include "string_ops.h"
using namespace metal;

// Match configuration
// Optimized with uchar4 vector types for SIMD operations
struct MatchConfig {
    uint num_names;           // Number of filenames to match
    uint pattern_len;         // Length of the pattern
    uint flags;               // Match flags
    uint max_name_len;        // Maximum filename length
    uint names_offset;        // Offset to names data
    uint names_lengths_offset; // Offset to name lengths
    uint _pad1;
    uint _pad2;
};

// Match flags
constant uint FLAG_CASE_INSENSITIVE = 1;
constant uint FLAG_MATCH_PATH = 2;      // Match full path instead of basename
constant uint FLAG_PERIOD = 4;          // Leading period must be matched explicitly

// Result for each filename
struct MatchResult {
    uint name_idx;
    uint matched;
    uint _pad1;
    uint _pad2;
};

// Common functions from string_ops.h:
// to_lower, to_lower4, char_match, match4, find_basename_start

// Simple glob pattern matching (supports * and ?)
// This is a simplified fnmatch implementation for GPU
bool glob_match(
    constant uchar* pattern,
    uint pattern_len,
    constant uchar* name,
    uint name_len,
    bool case_insensitive,
    bool match_period
) {
    uint pi = 0;  // pattern index
    uint ni = 0;  // name index
    uint star_pi = UINT_MAX;  // position of last * in pattern
    uint star_ni = UINT_MAX;  // position in name when * was seen

    // Handle leading period rule
    if (match_period && name_len > 0 && name[0] == '.') {
        if (pattern_len == 0 || pattern[0] != '.') {
            return false;
        }
    }

    while (ni < name_len) {
        if (pi < pattern_len) {
            uchar pc = pattern[pi];
            uchar nc = name[ni];

            if (pc == '*') {
                // Star matches zero or more characters
                star_pi = pi;
                star_ni = ni;
                pi++;
                continue;
            } else if (pc == '?') {
                // Question mark matches exactly one character
                // But not a leading period if match_period is set
                if (match_period && ni == 0 && nc == '.') {
                    if (star_pi != UINT_MAX) {
                        pi = star_pi + 1;
                        ni = ++star_ni;
                        continue;
                    }
                    return false;
                }
                pi++;
                ni++;
                continue;
            } else if (pc == '[') {
                // Character class - simplified implementation
                bool negated = false;
                bool matched = false;
                uint ci = pi + 1;

                if (ci < pattern_len && (pattern[ci] == '!' || pattern[ci] == '^')) {
                    negated = true;
                    ci++;
                }

                // Find matching character in class
                while (ci < pattern_len && pattern[ci] != ']') {
                    uchar cc = pattern[ci];
                    // Handle range (e.g., a-z)
                    if (ci + 2 < pattern_len && pattern[ci + 1] == '-' && pattern[ci + 2] != ']') {
                        uchar range_start = cc;
                        uchar range_end = pattern[ci + 2];
                        uchar test_c = case_insensitive ? to_lower(nc) : nc;
                        uchar rs = case_insensitive ? to_lower(range_start) : range_start;
                        uchar re = case_insensitive ? to_lower(range_end) : range_end;
                        if (test_c >= rs && test_c <= re) {
                            matched = true;
                        }
                        ci += 3;
                    } else {
                        if (char_match(cc, nc, case_insensitive)) {
                            matched = true;
                        }
                        ci++;
                    }
                }

                // Skip to end of character class
                while (pi < pattern_len && pattern[pi] != ']') pi++;
                if (pi < pattern_len) pi++; // skip ']'

                if (negated) matched = !matched;

                if (!matched) {
                    if (star_pi != UINT_MAX) {
                        pi = star_pi + 1;
                        ni = ++star_ni;
                        continue;
                    }
                    return false;
                }
                ni++;
                continue;
            } else {
                // Regular character match
                if (char_match(pc, nc, case_insensitive)) {
                    pi++;
                    ni++;
                    continue;
                }
            }
        }

        // No match - try backtracking to last *
        if (star_pi != UINT_MAX) {
            pi = star_pi + 1;
            ni = ++star_ni;
            continue;
        }

        return false;
    }

    // Skip trailing stars in pattern
    while (pi < pattern_len && pattern[pi] == '*') {
        pi++;
    }

    return pi == pattern_len;
}

kernel void match_names(
    constant MatchConfig& config [[buffer(0)]],
    constant uchar* pattern [[buffer(1)]],
    constant uchar* names_data [[buffer(2)]],
    constant uint* name_offsets [[buffer(3)]],
    constant uint* name_lengths [[buffer(4)]],
    device MatchResult* results [[buffer(5)]],
    device atomic_uint* match_count [[buffer(6)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= config.num_names) return;

    // Get the filename for this thread
    uint name_offset = name_offsets[gid];
    uint name_len = name_lengths[gid];
    constant uchar* name = names_data + name_offset;

    bool case_insensitive = (config.flags & FLAG_CASE_INSENSITIVE) != 0;
    bool match_path = (config.flags & FLAG_MATCH_PATH) != 0;
    bool match_period = (config.flags & FLAG_PERIOD) != 0;

    // For -name, match against basename only
    // For -path, match against full path
    constant uchar* match_str = name;
    uint match_len = name_len;

    if (!match_path) {
        uint basename_start = find_basename_start(name, name_len);
        match_str = name + basename_start;
        match_len = name_len - basename_start;
    }

    bool matched = glob_match(
        pattern,
        config.pattern_len,
        match_str,
        match_len,
        case_insensitive,
        match_period
    );

    results[gid].name_idx = gid;
    results[gid].matched = matched ? 1 : 0;

    if (matched) {
        atomic_fetch_add_explicit(match_count, 1, memory_order_relaxed);
    }
}
