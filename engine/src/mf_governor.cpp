// SPDX-License-Identifier: GPL-3.0-or-later
#include "mf_governor.hpp"
#include <algorithm>
#include <cmath>
#include <vector>

namespace macframe {

static int quality_to_tier(float q) {
    q = std::clamp(q, 0.0f, 1.0f);
    if (q <= 0.05f) return 0;
    if (q <= 0.30f) return 1;
    if (q <= 0.60f) return 2;
    if (q <= 0.85f) return 3;
    return 4;
}

Governor::Governor(double out_fps, float quality_ceiling, bool adaptive)
    : budget_ms_(1000.0 / (out_fps > 1.0 ? out_fps : 60.0)),
      max_tier_(quality_to_tier(quality_ceiling)),
      current_tier_(max_tier_),
      adaptive_(adaptive) {}

void Governor::reset() {
    current_tier_ = max_tier_;
    head_ = 0;
    count_ = 0;
    avg_ms_ = 0.0;
    p99_ms_ = 0.0;
    over_budget_streak_ = 0;
    under_budget_streak_ = 0;
}

void Governor::set_params(float quality_ceiling, bool adaptive) {
    int new_max = quality_to_tier(quality_ceiling);
    if (new_max != max_tier_) {
        max_tier_ = new_max;
        if (!adaptive || current_tier_ > max_tier_) {
            current_tier_ = max_tier_;
        }
    }
    adaptive_ = adaptive;
    if (!adaptive_) {
        current_tier_ = max_tier_;
    }
}

void Governor::record_gpu_time_ms(double ms) {
    if (ms < 0.0) ms = 0.0;
    samples_[head_] = ms;
    head_ = (head_ + 1) % kWindow;
    if (count_ < kWindow) count_++;

    double sum = 0.0;
    std::vector<double> sorted;
    sorted.reserve(count_);
    for (size_t i = 0; i < count_; ++i) {
        sum += samples_[i];
        sorted.push_back(samples_[i]);
    }
    avg_ms_ = sum / static_cast<double>(count_);
    std::sort(sorted.begin(), sorted.end());
    size_t idx99 = static_cast<size_t>(std::floor(0.98 * static_cast<double>(count_ - 1)));
    p99_ms_ = sorted[idx99];

    if (!adaptive_) return;

    if (ms > budget_ms_ * 0.82 || (count_ >= 8 && avg_ms_ > budget_ms_ * 0.78)) {
        over_budget_streak_++;
        under_budget_streak_ = 0;
        if (over_budget_streak_ >= 4 && current_tier_ > 0) {
            current_tier_--;
            over_budget_streak_ = 0;
            count_ = 0;
            head_ = 0;
        }
    } else if (ms < budget_ms_ * 0.40 && avg_ms_ < budget_ms_ * 0.42) {
        under_budget_streak_++;
        over_budget_streak_ = 0;
        if (under_budget_streak_ >= 24 && current_tier_ < max_tier_) {
            current_tier_++;
            under_budget_streak_ = 0;
            count_ = 0;
            head_ = 0;
        }
    } else {
        over_budget_streak_ = 0;
        under_budget_streak_ = 0;
    }
}

TierParams Governor::params_for_tier(int tier) {
    switch (std::clamp(tier, 0, 4)) {
        case 4:
            return {4, 2, 6, 2, 4, true};
        case 3:
            return {3, 2, 5, 2, 2, true};
        case 2:
            return {2, 2, 4, 1, 1, true};
        case 1:
            return {1, 4, 4, 1, 1, false};
        default:
            return {0, 4, 1, 0, 0, false};
    }
}

TierParams Governor::tier_params() const {
    return params_for_tier(current_tier_);
}

} // namespace macframe
