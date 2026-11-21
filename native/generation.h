#pragma once

#include "llama.h"

#include <algorithm>
#include <cstdlib>
#include <set>
#include <vector>

// The Voxt MLX runtime uses the same 24-token window and collapse thresholds.
inline constexpr size_t voxt_loop_window = 24;

inline bool voxt_is_loop(const std::vector<llama_token> & tokens) {
    if (tokens.size() < voxt_loop_window) {
        return false;
    }
    const std::set<llama_token> distinct(tokens.end() - voxt_loop_window, tokens.end());
    return distinct.size() <= 3;
}

inline void voxt_collapse_loop(std::vector<llama_token> & tokens) {
    const size_t count = tokens.size();
    for (size_t unit = 1; 2 * unit <= std::min(count, voxt_loop_window); ++unit) {
        size_t start = count - unit;
        while (start > 0 && tokens[start - 1] == tokens[start - 1 + unit]) {
            --start;
        }
        if (count - start >= std::max(voxt_loop_window / 2, 2 * unit)) {
            tokens.resize(start + unit);
            return;
        }
    }
}

inline bool voxt_profile_enabled() {
    static const bool enabled = [] {
        const char * value = std::getenv("OMNI_DFLASH_PROFILE");
        return value && value[0] == '1' && value[1] == '\0';
    }();
    return enabled;
}

inline bool voxt_trace_enabled() {
    static const bool enabled = [] {
        const char * value = std::getenv("VOXT_ASR_TRACE");
        return value && value[0] == '1' && value[1] == '\0';
    }();
    return enabled;
}
