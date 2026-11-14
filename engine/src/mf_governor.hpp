// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <array>
#include <cstddef>

namespace macframe {

struct TierParams {
    int  tier;               // 0..4
    int  me_divisor;         // 1 = full res, 2 = half res
    int  pyramid_levels;     // 4..6
    int  search_iters;       // 3DRS iterations per level
    int  dis_iters;          // DIS refinement iterations
    bool bidirectional;      // true = fwd+bwd consistency, false = fwd symmetric
};

class Governor {
public:
    Governor(double out_fps, float quality_ceiling, bool adaptive);

    void reset();
    void set_params(float quality_ceiling, bool adaptive);
    void record_gpu_time_ms(double ms);

    int current_tier() const { return current_tier_; }
    int max_tier() const { return max_tier_; }
    double avg_ms() const { return avg_ms_; }
    double p99_ms() const { return p99_ms_; }
    double budget_ms() const { return budget_ms_; }

    TierParams tier_params() const;
    static TierParams params_for_tier(int tier);

private:
    double budget_ms_;
    int    max_tier_;
    int    current_tier_;
    bool   adaptive_;

    static constexpr size_t kWindow = 64;
    std::array<double, kWindow> samples_{};
    size_t head_ = 0;
    size_t count_ = 0;

    double avg_ms_ = 0.0;
    double p99_ms_ = 0.0;
    int    over_budget_streak_ = 0;
    int    under_budget_streak_ = 0;
};

} // namespace macframe
