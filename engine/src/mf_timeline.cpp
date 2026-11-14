// SPDX-License-Identifier: GPL-3.0-or-later
#include "mf_timeline.hpp"
#include <algorithm>
#include <cmath>

namespace macframe {

Timeline::Timeline(double out_fps, bool dedup_enabled, bool scene_detect_enabled, float smoothness)
    : out_fps_(out_fps > 1.0 ? out_fps : 60.0),
      out_dt_(1.0 / out_fps_),
      dedup_enabled_(dedup_enabled),
      scene_detect_enabled_(scene_detect_enabled),
      smoothness_(std::clamp(smoothness, 0.0f, 1.0f)) {}

void Timeline::reset() {
    started_ = false;
    flushed_ = false;
    next_out_pts_ = 0.0;
    consecutive_dups_ = 0;
    queue_.clear();
    ready_.clear();
}

void Timeline::set_params(bool dedup_enabled, bool scene_detect_enabled, float smoothness) {
    dedup_enabled_ = dedup_enabled;
    scene_detect_enabled_ = scene_detect_enabled;
    smoothness_ = std::clamp(smoothness, 0.0f, 1.0f);
}

float Timeline::shape_phase(float t, float smoothness) {
    t = std::clamp(t, 0.0f, 1.0f);
    smoothness = std::clamp(smoothness, 0.0f, 1.0f);
    // When smoothness == 1.0, pure linear phase t.
    // When smoothness < 1.0, blend toward a steeper S-curve centered at 0.5
    // to preserve filmic cadence while still softening judder.
    float s = t * t * (3.0f - 2.0f * t);
    float s2 = s * s * (3.0f - 2.0f * s);
    return smoothness * t + (1.0f - smoothness) * s2;
}

void Timeline::push(const TimelineInputFrame &frame) {
    if (!started_) {
        started_ = true;
        next_out_pts_ = frame.pts;
        consecutive_dups_ = 0;
        queue_.push_back(frame);
        return;
    }

    // Handle duplicate frame collapsing for anime 2s/3s when dedup is enabled:
    // If the incoming frame is marked duplicate (and not a scene cut), and we have
    // collapsed fewer than kMaxCollapsedDups in a row, we tentatively hold it in queue
    // until a non-duplicate arrives (or max dups is exceeded).
    queue_.push_back(frame);
    advance(false);
}

void Timeline::flush() {
    flushed_ = true;
    advance(true);
}

void Timeline::advance(bool flushing) {
    while (queue_.size() >= 2) {
        if (dedup_enabled_ && queue_.size() >= 3) {
            // Check if middle frame(s) are collapsible duplicates
            // Look ahead from queue_[0] for up to kMaxCollapsedDups duplicate frames
            size_t collapse_count = 0;
            for (size_t i = 1; i + 1 < queue_.size() && collapse_count < (size_t)kMaxCollapsedDups; ++i) {
                if (queue_[i].is_duplicate && !queue_[i].is_scene_cut) {
                    collapse_count++;
                } else {
                    break;
                }
            }
            if (collapse_count > 0) {
                size_t next_idx = collapse_count + 1;
                if (next_idx < queue_.size()) {
                    // If the frame after the duplicates is NOT a duplicate (new drawing!),
                    // and not a scene cut, collapse the intermediate duplicates so motion
                    // interpolates smoothly across the entire multi-frame span!
                    if (!queue_[next_idx].is_duplicate && !queue_[next_idx].is_scene_cut) {
                        for (size_t c = 0; c < collapse_count; ++c) {
                            queue_.erase(queue_.begin() + 1);
                            dedup_drops_++;
                        }
                    } else if (queue_[next_idx].is_duplicate && collapse_count == (size_t)kMaxCollapsedDups) {
                        // More than kMaxCollapsedDups duplicates in a row -> genuine static hold!
                        // Do not collapse; emit first span normally.
                    }
                }
            }
        } else if (dedup_enabled_ && !flushing && queue_.size() == 2) {
            // If queue_[1] is a duplicate, wait for one more frame to know if it's 2s/3s or a static hold
            if (queue_[1].is_duplicate && !queue_[1].is_scene_cut) {
                break;
            }
        }

        // Wait one more frame if queue_[1] is clean but queue_ only has 2 elements and dedup is enabled?
        // Actually, if queue_[1] is not a duplicate, could queue_[2] be a duplicate of queue_[1]?
        // Yes! If queue_[1] is a new drawing and queue_[2] is a duplicate of queue_[1] (i.e. queue_[1] starts a 2-frame hold),
        // queue_[0] -> queue_[1] was only 1 frame if queue_[0] wasn't held, OR queue_[1] is the start of the NEXT span.
        // Because queue_[1] stays at queue_[0] after emitting span (queue_[0], queue_[1]),
        // when queue_[2] arrives later, queue_[1] is STILL at the front of queue_ and can collapse queue_[2]!
        // So we DO NOT need to delay when queue_[1] is not a duplicate! That keeps latency to 1 frame!

        const TimelineInputFrame f0 = queue_[0];
        const TimelineInputFrame f1 = queue_[1];
        emit_span(f0, f1);
        queue_.pop_front();
    }

    if (flushing && queue_.size() == 1) {
        const TimelineInputFrame &last = queue_.front();
        if (next_out_pts_ <= last.pts + out_dt_ * 0.5) {
            TimelineOutputTask t{};
            t.f0_id = last.id;
            t.f1_id = last.id;
            t.out_pts = last.pts;
            t.raw_phase = 0.0f;
            t.shaped_phase = 0.0f;
            t.mode = OutputMode::PassthroughF0;
            ready_.push_back(t);
        }
        queue_.clear();
    }
}

void Timeline::emit_span(const TimelineInputFrame &f0, const TimelineInputFrame &f1) {
    double span = f1.pts - f0.pts;
    if (span <= 1e-6) {
        return;
    }
    bool is_cut = scene_detect_enabled_ && f1.is_scene_cut;
    if (is_cut) {
        scene_cuts_++;
    }

    // Re-sync if timestamps jumped
    if (next_out_pts_ < f0.pts - out_dt_ * 2.0 || next_out_pts_ > f1.pts + span * 2.0) {
        next_out_pts_ = f0.pts;
    }

    while (next_out_pts_ < f1.pts - 1e-6) {
        float raw_t = static_cast<float>((next_out_pts_ - f0.pts) / span);
        raw_t = std::clamp(raw_t, 0.0f, 1.0f);
        float shaped_t = shape_phase(raw_t, smoothness_);

        TimelineOutputTask task{};
        task.f0_id = f0.id;
        task.f1_id = f1.id;
        task.out_pts = next_out_pts_;
        task.raw_phase = raw_t;
        task.shaped_phase = shaped_t;
        task.is_scene_cut_span = is_cut;

        if (is_cut) {
            task.mode = (raw_t < 0.5f) ? OutputMode::PassthroughF0 : OutputMode::PassthroughF1;
            task.shaped_phase = (raw_t < 0.5f) ? 0.0f : 1.0f;
        } else if (shaped_t <= 0.01f) {
            task.mode = OutputMode::PassthroughF0;
            task.shaped_phase = 0.0f;
        } else if (shaped_t >= 0.99f) {
            task.mode = OutputMode::PassthroughF1;
            task.shaped_phase = 1.0f;
        } else {
            task.mode = OutputMode::Interpolate;
        }

        ready_.push_back(task);
        next_out_pts_ += out_dt_;
    }
}

bool Timeline::has_ready_output() const {
    return !ready_.empty();
}

TimelineOutputTask Timeline::pop_output() {
    TimelineOutputTask t = ready_.front();
    ready_.pop_front();
    return t;
}

} // namespace macframe
