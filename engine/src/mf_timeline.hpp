// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <cstdint>
#include <deque>
#include <vector>

namespace macframe {

enum class OutputMode {
    PassthroughF0,
    PassthroughF1,
    Interpolate,
};

struct TimelineInputFrame {
    uint64_t id = 0;
    double   pts = 0.0;
    bool     is_duplicate = false; // frame is nearly identical to previous frame
    bool     is_scene_cut = false; // cut occurs between previous frame and this frame
};

struct TimelineOutputTask {
    uint64_t   f0_id = 0;
    uint64_t   f1_id = 0;
    double     out_pts = 0.0;
    float      raw_phase = 0.0f;    // linear phase in [0, 1]
    float      shaped_phase = 0.0f; // phase after smoothness shaping
    OutputMode mode = OutputMode::PassthroughF0;
    bool       is_scene_cut_span = false;
};

class Timeline {
public:
    Timeline(double out_fps, bool dedup_enabled, bool scene_detect_enabled, float smoothness);

    void reset();
    void push(const TimelineInputFrame &frame);
    void flush();

    bool has_ready_output() const;
    TimelineOutputTask pop_output();

    uint64_t scene_cuts() const { return scene_cuts_; }
    uint64_t dedup_drops() const { return dedup_drops_; }

    static float shape_phase(float t, float smoothness);

private:
    void advance(bool flushing);
    void emit_span(const TimelineInputFrame &f0, const TimelineInputFrame &f1);

    double out_fps_;
    double out_dt_;
    bool   dedup_enabled_;
    bool   scene_detect_enabled_;
    float  smoothness_;

    bool   started_ = false;
    bool   flushed_ = false;
    double next_out_pts_ = 0.0;
    int    consecutive_dups_ = 0;
    static constexpr int kMaxCollapsedDups = 2; // collapse 2s and 3s (1 or 2 dups); >2 is a hold

    std::deque<TimelineInputFrame> queue_;
    std::deque<TimelineOutputTask> ready_;

    uint64_t scene_cuts_ = 0;
    uint64_t dedup_drops_ = 0;
};

} // namespace macframe
