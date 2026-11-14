// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

namespace macframe {

static const char *kMacFrameShaderSource = R"MSL(
#include <metal_stdlib>
using namespace metal;

constexpr sampler kLinearClamp(coord::normalized, address::clamp_to_edge, filter::linear);
constexpr sampler kNearestClamp(coord::pixel, address::clamp_to_edge, filter::nearest);

kernel void clear_texture_rgba16f(
    texture2d<half, access::write> dst [[texture(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    dst.write(half4(0.0h), gid);
}

struct PreprocessParams {
    uint2 dst_size;
    float2 inv_src_size;
    uint is_video_range;
};

// 1. Extract Luma from Y plane (8-bit or 16-bit normalized) with 3x3 noise-reduction prefilter
kernel void extract_luma_y(
    texture2d<half, access::sample> src_y [[texture(0)]],
    texture2d<half, access::write> dst_luma [[texture(1)]],
    constant PreprocessParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.dst_size.x || gid.y >= p.dst_size.y) return;
    float2 uv = (float2(gid) + 0.5f) / float2(p.dst_size);
    float2 d = p.inv_src_size;

    half c00 = src_y.sample(kLinearClamp, uv + float2(-d.x, -d.y)).r;
    half c10 = src_y.sample(kLinearClamp, uv + float2( 0.0f, -d.y)).r;
    half c20 = src_y.sample(kLinearClamp, uv + float2( d.x, -d.y)).r;
    half c01 = src_y.sample(kLinearClamp, uv + float2(-d.x,  0.0f)).r;
    half c11 = src_y.sample(kLinearClamp, uv).r;
    half c21 = src_y.sample(kLinearClamp, uv + float2( d.x,  0.0f)).r;
    half c02 = src_y.sample(kLinearClamp, uv + float2(-d.x,  d.y)).r;
    half c12 = src_y.sample(kLinearClamp, uv + float2( 0.0f,  d.y)).r;
    half c22 = src_y.sample(kLinearClamp, uv + float2( d.x,  d.y)).r;

    half y = (c00 + c20 + c02 + c22 + 2.0h * (c10 + c01 + c21 + c12) + 4.0h * c11) * (1.0h / 16.0h);
    if (p.is_video_range != 0) {
        y = clamp((y - 0.0625h) * 1.16438h, 0.0h, 1.0h);
    }
    dst_luma.write(half4(y, 0.0h, 0.0h, 1.0h), gid);
}

// 1b. Extract Luma from BGRA texture
kernel void extract_luma_bgra(
    texture2d<half, access::sample> src_bgra [[texture(0)]],
    texture2d<half, access::write> dst_luma [[texture(1)]],
    constant PreprocessParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.dst_size.x || gid.y >= p.dst_size.y) return;
    float2 uv = (float2(gid) + 0.5f) / float2(p.dst_size);
    half4 rgb = src_bgra.sample(kLinearClamp, uv);
    half y = dot(rgb.rgb, half3(0.2126h, 0.7152h, 0.0722h));
    dst_luma.write(half4(y, 0.0h, 0.0h, 1.0h), gid);
}

// 2. Gaussian 2x Pyramid Downsample
kernel void pyramid_downsample(
    texture2d<half, access::sample> src [[texture(0)]],
    texture2d<half, access::write> dst [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint w = dst.get_width();
    uint h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float2 inv_src = 1.0f / float2(src.get_width(), src.get_height());
    float2 center = (float2(gid) * 2.0f + 1.0f) * inv_src;

    half s0 = src.sample(kLinearClamp, center + float2(-inv_src.x, -inv_src.y)).r;
    half s1 = src.sample(kLinearClamp, center + float2( inv_src.x, -inv_src.y)).r;
    half s2 = src.sample(kLinearClamp, center + float2(-inv_src.x,  inv_src.y)).r;
    half s3 = src.sample(kLinearClamp, center + float2( inv_src.x,  inv_src.y)).r;
    half sc = src.sample(kLinearClamp, center).r;

    half val = 0.125h * (s0 + s1 + s2 + s3) + 0.5h * sc;
    dst.write(half4(val, 0.0h, 0.0h, 1.0h), gid);
}

// 3. Pair Analysis on Coarse Pyramid (Scene Cut, Duplicate Detection, Letterbox)
struct PairAnalysisResult {
    atomic_uint diff_sum_fixed;     // sum of |I0 - I1| * 1024
    atomic_uint max_block_diff;     // max 8x8 block SAD * 1024
    atomic_uint grad_sum_fixed;     // sum of spatial gradients * 1024
    atomic_uint hist0[32];
    atomic_uint hist1[32];
    atomic_uint row_luma_sum[512];  // for letterbox detection (up to 512 coarse rows)
    atomic_uint row_grad_sum[512];
};

kernel void clear_pair_analysis(
    device PairAnalysisResult *res [[buffer(0)]],
    uint tid [[thread_position_in_grid]])
{
    if (tid == 0) {
        atomic_store_explicit(&res->diff_sum_fixed, 0u, memory_order_relaxed);
        atomic_store_explicit(&res->max_block_diff, 0u, memory_order_relaxed);
        atomic_store_explicit(&res->grad_sum_fixed, 0u, memory_order_relaxed);
    }
    if (tid < 32) {
        atomic_store_explicit(&res->hist0[tid], 0u, memory_order_relaxed);
        atomic_store_explicit(&res->hist1[tid], 0u, memory_order_relaxed);
    }
    if (tid < 512) {
        atomic_store_explicit(&res->row_luma_sum[tid], 0u, memory_order_relaxed);
        atomic_store_explicit(&res->row_grad_sum[tid], 0u, memory_order_relaxed);
    }
}

kernel void analyze_pair_coarse(
    texture2d<half, access::read> luma0 [[texture(0)]],
    texture2d<half, access::read> luma1 [[texture(1)]],
    device PairAnalysisResult *res [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 lid [[thread_position_in_threadgroup]],
    uint2 tg_size [[threads_per_threadgroup]])
{
    uint w = luma0.get_width();
    uint h = luma0.get_height();
    threadgroup atomic_uint local_diff_sum;
    threadgroup atomic_uint local_grad_sum;
    if (lid.x == 0 && lid.y == 0) {
        atomic_store_explicit(&local_diff_sum, 0u, memory_order_relaxed);
        atomic_store_explicit(&local_grad_sum, 0u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (gid.x < w && gid.y < h) {
        float v0 = float(luma0.read(gid).r);
        float v1 = float(luma1.read(gid).r);
        float rx = (gid.x + 1 < w) ? float(luma0.read(gid + uint2(1, 0)).r) : v0;
        float ry = (gid.y + 1 < h) ? float(luma0.read(gid + uint2(0, 1)).r) : v0;
        float gx = fabs(rx - v0) + fabs(ry - v0);
        float d = fabs(v0 - v1);

        uint d_fixed = uint(clamp(d * 1024.0f, 0.0f, 1024.0f));
        uint g_fixed = uint(clamp(gx * 1024.0f, 0.0f, 2048.0f));
        atomic_fetch_add_explicit(&local_diff_sum, d_fixed, memory_order_relaxed);
        atomic_fetch_add_explicit(&local_grad_sum, g_fixed, memory_order_relaxed);

        uint b0 = min(uint(clamp(v0, 0.0f, 0.999f) * 32.0f), 31u);
        uint b1 = min(uint(clamp(v1, 0.0f, 0.999f) * 32.0f), 31u);
        atomic_fetch_add_explicit(&res->hist0[b0], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&res->hist1[b1], 1u, memory_order_relaxed);

        if (gid.y < 512) {
            uint luma_fixed = uint(clamp(max(v0, v1) * 1024.0f, 0.0f, 1024.0f));
            atomic_fetch_add_explicit(&res->row_luma_sum[gid.y], luma_fixed, memory_order_relaxed);
            atomic_fetch_add_explicit(&res->row_grad_sum[gid.y], g_fixed, memory_order_relaxed);
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (lid.x == 0 && lid.y == 0) {
        uint block_px = tg_size.x * tg_size.y;
        uint d_sum = atomic_load_explicit(&local_diff_sum, memory_order_relaxed);
        uint g_sum = atomic_load_explicit(&local_grad_sum, memory_order_relaxed);
        uint block_avg = d_sum / max(block_px, 1u);
        atomic_fetch_add_explicit(&res->diff_sum_fixed, d_sum, memory_order_relaxed);
        atomic_fetch_add_explicit(&res->grad_sum_fixed, g_sum, memory_order_relaxed);
        atomic_fetch_max_explicit(&res->max_block_diff, block_avg, memory_order_relaxed);
    }
}

// 4. Static Region / Logo / HUD / Hard-Subtitle Lock Update
kernel void update_static_mask(
    texture2d<half, access::sample> luma0 [[texture(0)]],
    texture2d<half, access::sample> luma1 [[texture(1)]],
    texture2d<half, access::read> prev_static [[texture(2)]],
    texture2d<half, access::write> next_static [[texture(3)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint w = next_static.get_width();
    uint h = next_static.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float2 inv = 1.0f / float2(w, h);
    float2 uv = (float2(gid) + 0.5f) * inv;

    float c0 = float(luma0.sample(kLinearClamp, uv).r);
    float c1 = float(luma1.sample(kLinearClamp, uv).r);
    float diff = fabs(c0 - c1);

    // Local spatial structure (HUD/logos/text have non-zero spatial contrast)
    float l = float(luma0.sample(kLinearClamp, uv + float2(-inv.x, 0.0f)).r);
    float r = float(luma0.sample(kLinearClamp, uv + float2( inv.x, 0.0f)).r);
    float u = float(luma0.sample(kLinearClamp, uv + float2(0.0f, -inv.y)).r);
    float d = float(luma0.sample(kLinearClamp, uv + float2(0.0f,  inv.y)).r);
    float edge = fabs(r - l) + fabs(d - u);

    float prev = float(prev_static.read(gid).r);
    float next_val = 0.0f;
    if (diff < 0.0055f && edge > 0.035f) {
        next_val = min(prev + 0.25f, 1.0f);
    } else if (diff < 0.0085f) {
        next_val = prev * 0.85f;
    } else {
        next_val = 0.0f;
    }
    next_static.write(half4(half(next_val), 0.0h, 0.0h, 1.0h), gid);
}

// 5. Hierarchical Motion Estimation (3DRS + Diamond Search + Zero-Mean & Gradient Cost)
struct MESearchParams {
    uint2 size;
    float2 inv_size;
    float grad_weight;      // higher for anime (e.g. 0.55), normal ~0.35
    float smooth_lambda;    // motion smoothness regularization
    int search_radius;      // diamond radius in pixels at this level
    int is_coarsest;
};

static inline float patch_cost(
    texture2d<half, access::sample> I0,
    texture2d<half, access::sample> I1,
    float2 pos,
    float2 mv,
    float2 inv_size,
    float grad_weight)
{
    // 5-point cross + 4-corner 9-tap zero-mean + gradient cost on 4x4 neighborhood
    const float2 offsets[9] = {
        float2( 0.0f,  0.0f),
        float2(-2.0f,  0.0f), float2( 2.0f,  0.0f),
        float2( 0.0f, -2.0f), float2( 0.0f,  2.0f),
        float2(-1.0f, -1.0f), float2( 1.0f, -1.0f),
        float2(-1.0f,  1.0f), float2( 1.0f,  1.0f)
    };

    float v0[9], v1[9];
    float sum0 = 0.0f, sum1 = 0.0f;
    for (int i = 0; i < 9; ++i) {
        float2 uv0 = (pos + offsets[i]) * inv_size;
        float2 uv1 = (pos + mv + offsets[i]) * inv_size;
        v0[i] = float(I0.sample(kLinearClamp, uv0).r);
        v1[i] = float(I1.sample(kLinearClamp, uv1).r);
        sum0 += v0[i];
        sum1 += v1[i];
    }
    float mean_diff = (sum0 - sum1) * (1.0f / 9.0f);

    float sad = 0.0f;
    for (int i = 0; i < 9; ++i) {
        // Zero-mean compensated residual (resilient to fades/lighting shifts)
        float raw_d = fabs(v0[i] - v1[i]);
        float zm_d  = fabs((v0[i] - v1[i]) - mean_diff * 0.65f);
        sad += min(raw_d, zm_d + 0.004f);
    }

    // Horizontal & vertical gradient differences across the patch
    float gx0 = v0[2] - v0[1], gx1 = v1[2] - v1[1];
    float gy0 = v0[4] - v0[3], gy1 = v1[4] - v1[3];
    float gd1 = (v0[8] - v0[5]) - (v1[8] - v1[5]);
    float gd2 = (v0[7] - v0[6]) - (v1[7] - v1[6]);
    float grad_err = (fabs(gx0 - gx1) + fabs(gy0 - gy1) + fabs(gd1) + fabs(gd2)) * 2.25f;

    return (1.0f - grad_weight) * sad + grad_weight * grad_err;
}

kernel void me_hierarchical_search(
    texture2d<half, access::sample> I0 [[texture(0)]],
    texture2d<half, access::sample> I1 [[texture(1)]],
    texture2d<half, access::sample> prev_level_flow [[texture(2)]],
    texture2d<half, access::sample> temporal_flow [[texture(3)]],
    texture2d<half, access::write> out_flow [[texture(4)]],
    constant MESearchParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.size.x || gid.y >= p.size.y) return;

    float2 pos = float2(gid) + 0.5f;
    float2 uv = pos * p.inv_size;

    // Candidate 0: zero motion (critical for static backgrounds, HUDs, tripod shots)
    float2 best_mv = float2(0.0f, 0.0f);
    float2 prior_mv = float2(0.0f, 0.0f);

    if (p.is_coarsest == 0) {
        prior_mv = float2(prev_level_flow.sample(kLinearClamp, uv).rg) * 2.0f;
    }

    float best_cost = patch_cost(I0, I1, pos, best_mv, p.inv_size, p.grad_weight)
                    + p.smooth_lambda * length(best_mv - prior_mv);

    auto test_candidate = [&](float2 cand) {
        float c = patch_cost(I0, I1, pos, cand, p.inv_size, p.grad_weight)
                + p.smooth_lambda * length(cand - prior_mv);
        if (c < best_cost) {
            best_cost = c;
            best_mv = cand;
        }
    };

    if (p.is_coarsest == 0) {
        // Test upsampled parent & spatial 3DRS neighbors from parent level
        test_candidate(prior_mv);
        float2 step_uv = p.inv_size * 4.0f;
        test_candidate(float2(prev_level_flow.sample(kLinearClamp, uv + float2(-step_uv.x, 0.0f)).rg) * 2.0f);
        test_candidate(float2(prev_level_flow.sample(kLinearClamp, uv + float2( step_uv.x, 0.0f)).rg) * 2.0f);
        test_candidate(float2(prev_level_flow.sample(kLinearClamp, uv + float2(0.0f, -step_uv.y)).rg) * 2.0f);
        test_candidate(float2(prev_level_flow.sample(kLinearClamp, uv + float2(0.0f,  step_uv.y)).rg) * 2.0f);
    }

    // Test temporal predictor (scaled to current level)
    float2 temp_mv = float2(temporal_flow.sample(kLinearClamp, uv).rg);
    test_candidate(temp_mv);

    // Coarse-to-fine diamond search around best candidate
    for (int step = p.search_radius; step >= 1; step >>= 1) {
        float2 center = best_mv;
        float s = float(step);
        test_candidate(center + float2(-s,  0.0f));
        test_candidate(center + float2( s,  0.0f));
        test_candidate(center + float2( 0.0f, -s));
        test_candidate(center + float2( 0.0f,  s));
        test_candidate(center + float2(-s, -s));
        test_candidate(center + float2( s, -s));
        test_candidate(center + float2(-s,  s));
        test_candidate(center + float2( s,  s));
    }

    out_flow.write(half4(half2(best_mv), half(best_cost), 0.0h), gid);
}

// 6. Edge-Aware Bilateral / Vector-Median Flow Smoothing
kernel void flow_bilateral_smooth(
    texture2d<half, access::read> I0 [[texture(0)]],
    texture2d<half, access::read> in_flow [[texture(1)]],
    texture2d<half, access::write> out_flow [[texture(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint w = in_flow.get_width();
    uint h = in_flow.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float c_luma = float(I0.read(gid).r);
    half4 center_f = in_flow.read(gid);
    float2 sum_mv = float2(0.0f);
    float sum_w = 0.0f;

    for (int dy = -1; dy <= 1; ++dy) {
        int ny = clamp(int(gid.y) + dy, 0, int(h) - 1);
        for (int dx = -1; dx <= 1; ++dx) {
            int nx = clamp(int(gid.x) + dx, 0, int(w) - 1);
            uint2 np = uint2(nx, ny);
            float nl = float(I0.read(np).r);
            half4 nf = in_flow.read(np);

            float w_luma = exp(-fabs(nl - c_luma) * 18.0f);
            float w_cost = exp(-float(nf.b) * 2.5f);
            float w_sp   = (dx == 0 && dy == 0) ? 2.0f : 1.0f;
            float weight = w_luma * w_cost * w_sp + 1e-4f;

            sum_mv += float2(nf.rg) * weight;
            sum_w  += weight;
        }
    }

    float2 smoothed = sum_mv / sum_w;
    out_flow.write(half4(half2(smoothed), center_f.b, 0.0h), gid);
}

// 7. DIS (Dense Inverse Search / Lucas-Kanade) Sub-Pixel Optical Flow Refinement
kernel void flow_refine_dis(
    texture2d<half, access::sample> I0 [[texture(0)]],
    texture2d<half, access::sample> I1 [[texture(1)]],
    texture2d<half, access::read> in_flow [[texture(2)]],
    texture2d<half, access::write> out_flow [[texture(3)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint w = in_flow.get_width();
    uint h = in_flow.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float2 inv_size = 1.0f / float2(w, h);
    float2 pos = float2(gid) + 0.5f;
    half4 f_in = in_flow.read(gid);
    float2 mv = float2(f_in.rg);

    // 2x2 structure tensor over 3x3 window
    float s_xx = 1e-3f, s_xy = 0.0f, s_yy = 1e-3f;
    float b_x = 0.0f, b_y = 0.0f;

    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            float2 p0 = (pos + float2(dx, dy)) * inv_size;
            float2 p1 = (pos + mv + float2(dx, dy)) * inv_size;

            float i0 = float(I0.sample(kLinearClamp, p0).r);
            float i1 = float(I1.sample(kLinearClamp, p1).r);
            float it = i1 - i0;

            float ix = 0.5f * float(I0.sample(kLinearClamp, p0 + float2(inv_size.x, 0.0f)).r -
                                    I0.sample(kLinearClamp, p0 - float2(inv_size.x, 0.0f)).r);
            float iy = 0.5f * float(I0.sample(kLinearClamp, p0 + float2(0.0f, inv_size.y)).r -
                                    I0.sample(kLinearClamp, p0 - float2(0.0f, inv_size.y)).r);

            s_xx += ix * ix;
            s_xy += ix * iy;
            s_yy += iy * iy;
            b_x  -= ix * it;
            b_y  -= iy * it;
        }
    }

    float det = s_xx * s_yy - s_xy * s_xy;
    if (det > 1e-5f) {
        float2 delta = float2(s_yy * b_x - s_xy * b_y, -s_xy * b_x + s_xx * b_y) / det;
        // Clamp update step to prevent instability in aperture-problem areas
        float len = length(delta);
        if (len > 0.75f) {
            delta *= (0.75f / len);
        }
        mv += delta;
    }

    out_flow.write(half4(half2(mv), f_in.b, 0.0h), gid);
}

// 8. Forward-Backward Consistency, Visibility (v0, v1), Confidence & Static/Letterbox Clamping
struct ConsistencyParams {
    uint2 size;
    float2 inv_size;
    int bidirectional;
    int static_lock;
    int letterbox_top_me;
    int letterbox_bottom_me;
    float guard_strength;
};

struct ConfidenceStats {
    atomic_uint conf_sum_fixed;   // sum of confidence * 1024
    atomic_uint fallback_pixels;  // count of pixels where fallback > 0.25
};

kernel void compute_consistency(
    texture2d<half, access::sample> I0 [[texture(0)]],
    texture2d<half, access::sample> I1 [[texture(1)]],
    texture2d<half, access::sample> F01_tex [[texture(2)]],
    texture2d<half, access::sample> F10_tex [[texture(3)]],
    texture2d<half, access::sample> static_mask_tex [[texture(4)]],
    texture2d<half, access::read> prev_guard_tex [[texture(5)]],
    texture2d<half, access::write> out_F01_clean [[texture(6)]],
    texture2d<half, access::write> out_F10_clean [[texture(7)]],
    texture2d<half, access::write> out_vis_conf [[texture(8)]], // .r=v0, .g=v1, .b=guard_mask, .a=conf
    device ConfidenceStats *stats [[buffer(0)]],
    constant ConsistencyParams &p [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.size.x || gid.y >= p.size.y) return;

    float2 pos = float2(gid) + 0.5f;
    float2 uv = pos * p.inv_size;

    // Check letterbox region or static region lock
    bool in_letterbox = (int(gid.y) < p.letterbox_top_me) || (int(gid.y) >= p.letterbox_bottom_me);
    float static_w = (p.static_lock != 0) ? float(static_mask_tex.sample(kLinearClamp, uv).r) : 0.0f;

    if (in_letterbox || static_w > 0.72f) {
        out_F01_clean.write(half4(0.0h), gid);
        out_F10_clean.write(half4(0.0h), gid);
        out_vis_conf.write(half4(1.0h, 1.0h, 0.0h, 1.0h), gid);
        atomic_fetch_add_explicit(&stats->conf_sum_fixed, 1024u, memory_order_relaxed);
        return;
    }

    float2 f01 = float2(F01_tex.sample(kLinearClamp, uv).rg) * (1.0f - static_w);
    float2 f10;
    if (p.bidirectional != 0) {
        f10 = float2(F10_tex.sample(kLinearClamp, uv).rg) * (1.0f - static_w);
    } else {
        f10 = -f01;
    }

    // Clamp motion vectors that point outside the active picture (incl. letterbox boundaries)
    float min_y = float(p.letterbox_top_me) + 0.5f;
    float max_y = float(p.letterbox_bottom_me) - 0.5f;
    float2 dst01 = pos + f01;
    float2 dst10 = pos + f10;
    bool oob01 = (dst01.x < 0.5f || dst01.x > float(p.size.x) - 0.5f || dst01.y < min_y || dst01.y > max_y);
    bool oob10 = (dst10.x < 0.5f || dst10.x > float(p.size.x) - 0.5f || dst10.y < min_y || dst10.y > max_y);

    float2 bwd_at_fwd = (p.bidirectional != 0)
        ? float2(F10_tex.sample(kLinearClamp, dst01 * p.inv_size).rg)
        : -f01;
    float2 fwd_at_bwd = (p.bidirectional != 0)
        ? float2(F01_tex.sample(kLinearClamp, dst10 * p.inv_size).rg)
        : -f10;

    float err01 = length(f01 + bwd_at_fwd);
    float err10 = length(f10 + fwd_at_bwd);

    // Local flow deformation / divergence check (prevents jello/tearing artifacts)
    float2 f_r = float2(F01_tex.sample(kLinearClamp, uv + float2(p.inv_size.x, 0.0f)).rg);
    float2 f_d = float2(F01_tex.sample(kLinearClamp, uv + float2(0.0f, p.inv_size.y)).rg);
    float deform = length(f_r - f01) + length(f_d - f01);

    float i0 = float(I0.sample(kLinearClamp, uv).r);
    float i1_warped = float(I1.sample(kLinearClamp, dst01 * p.inv_size).r);
    float i0_warped = float(I0.sample(kLinearClamp, dst10 * p.inv_size).r);
    float i1 = float(I1.sample(kLinearClamp, uv).r);

    float photo01 = fabs(i0 - i1_warped);
    float photo10 = fabs(i1 - i0_warped);

    // Visibility weights v0 and v1 for occlusion-aware bidirectional synthesis
    float v0 = exp(-(err01 * err01) * 0.12f - photo01 * 6.0f) * (oob01 ? 0.05f : 1.0f);
    float v1 = exp(-(err10 * err10) * 0.12f - photo10 * 6.0f) * (oob10 ? 0.05f : 1.0f);
    v0 = clamp(v0, 0.01f, 1.0f);
    v1 = clamp(v1, 0.01f, 1.0f);

    float min_err = min(err01, err10);
    float min_photo = min(photo01, photo10);
    float conf = exp(-(min_err * min_err) * 0.08f - (min_photo * min_photo) * 18.0f - max(deform - 1.5f, 0.0f) * 0.25f);
    if (oob01 && oob10) conf *= 0.25f;
    conf = clamp(conf, 0.0f, 1.0f);

    // Compute local fallback guard mask with temporal smoothing to prevent flicker
    float raw_guard = clamp((1.0f - conf) * p.guard_strength * 1.4f, 0.0f, 1.0f);
    float prev_guard = float(prev_guard_tex.read(gid).b);
    float guard_mask = clamp(0.72f * raw_guard + 0.28f * prev_guard, 0.0f, 1.0f);

    out_F01_clean.write(half4(half2(f01), 0.0h, 0.0h), gid);
    out_F10_clean.write(half4(half2(f10), 0.0h, 0.0h), gid);
    out_vis_conf.write(half4(half(v0), half(v1), half(guard_mask), half(conf)), gid);

    atomic_fetch_add_explicit(&stats->conf_sum_fixed, uint(conf * 1024.0f), memory_order_relaxed);
    if (guard_mask > 0.25f) {
        atomic_fetch_add_explicit(&stats->fallback_pixels, 1u, memory_order_relaxed);
    }
}

// 9. Intermediate Phase Flow Projection (t in (0, 1))
// Evaluates forward-splatted and symmetric candidate trajectories around x_t,
// selecting the trajectory with highest visibility & lowest photometric residual.
struct PhaseProjectParams {
    uint2 size;
    float2 inv_size;
    float phase_t;
    float flow_scale; // scale factor when converting ME grid flow to full pixel coordinates
};

kernel void project_phase_flow(
    texture2d<half, access::sample> I0 [[texture(0)]],
    texture2d<half, access::sample> I1 [[texture(1)]],
    texture2d<half, access::sample> F01 [[texture(2)]],
    texture2d<half, access::sample> F10 [[texture(3)]],
    texture2d<half, access::sample> vis_conf [[texture(4)]],
    texture2d<half, access::write> out_Ft [[texture(5)]], // .rg = Ft->0, .ba = Ft->1 (in UV normalized offsets!)
    texture2d<half, access::write> out_vc_smooth [[texture(6)]],
    constant PhaseProjectParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.size.x || gid.y >= p.size.y) return;

    float2 pos = float2(gid) + 0.5f;
    float2 uv = pos * p.inv_size;
    float t = p.phase_t;

    // Spatial 3x3 feathering of vis_conf + candidate trajectory search
    float2 best_f0 = float2(0.0f);
    float2 best_f1 = float2(0.0f);
    float best_score = 1e9f;
    float4 vc_acc = float4(0.0f);

    const float2 offs[5] = {
        float2(0.0f, 0.0f),
        float2(-2.0f, 0.0f), float2(2.0f, 0.0f),
        float2(0.0f, -2.0f), float2(0.0f, 2.0f)
    };

    for (int i = 0; i < 5; ++i) {
        float2 sample_uv = (pos + offs[i]) * p.inv_size;
        float4 vc = float4(vis_conf.sample(kLinearClamp, sample_uv));
        vc_acc += vc * ((i == 0) ? 2.0f : 1.0f);

        // Candidate A: forward flow at sample_uv traced back by -t * f01
        float2 f01_a = float2(F01.sample(kLinearClamp, sample_uv).rg);
        float2 src0_uv = (pos - t * f01_a) * p.inv_size;
        float2 f01 = float2(F01.sample(kLinearClamp, src0_uv).rg);
        float2 ft0_a = -t * f01;
        float2 ft1_a = (1.0f - t) * f01;

        float l0_a = float(I0.sample(kLinearClamp, (pos + ft0_a) * p.inv_size).r);
        float l1_a = float(I1.sample(kLinearClamp, (pos + ft1_a) * p.inv_size).r);
        float score_a = fabs(l0_a - l1_a) / max(vc.x, 0.1f);
        if (score_a < best_score) {
            best_score = score_a;
            best_f0 = ft0_a;
            best_f1 = ft1_a;
        }

        // Candidate B: backward flow at sample_uv traced back by -(1-t) * f10
        float2 f10_b = float2(F10.sample(kLinearClamp, sample_uv).rg);
        float2 src1_uv = (pos - (1.0f - t) * f10_b) * p.inv_size;
        float2 f10 = float2(F10.sample(kLinearClamp, src1_uv).rg);
        float2 ft0_b = t * f10;
        float2 ft1_b = -(1.0f - t) * f10;

        float l0_b = float(I0.sample(kLinearClamp, (pos + ft0_b) * p.inv_size).r);
        float l1_b = float(I1.sample(kLinearClamp, (pos + ft1_b) * p.inv_size).r);
        float score_b = fabs(l0_b - l1_b) / max(vc.y, 0.1f);
        if (score_b < best_score) {
            best_score = score_b;
            best_f0 = ft0_b;
            best_f1 = ft1_b;
        }
    }

    vc_acc *= (1.0f / 6.0f);
    // Store normalized UV displacement so synthesis works at any output resolution
    float2 uv_ft0 = best_f0 * p.inv_size;
    float2 uv_ft1 = best_f1 * p.inv_size;

    out_Ft.write(half4(half2(uv_ft0), half2(uv_ft1)), gid);
    out_vc_smooth.write(half4(vc_acc), gid);
}

// 10. Occlusion-Aware + Artifact-Guarded Synthesis for NV12 / P010 (Bi-Planar Y + UV)
struct SynthParams {
    uint2 y_size;
    uint2 uv_size;
    float phase_t;
    float global_fallback_alpha; // >0 when frame-wide confidence is critically low
    int is_anime_preset;         // 1 = prefer nearest crisp frame on fallback to avoid double lines
    int letterbox_top;
    int letterbox_bottom;
    int debug_osd;
    int current_tier;
};

static inline half4 sample_warped_guarded(
    texture2d<half, access::sample> tex0,
    texture2d<half, access::sample> tex1,
    float2 uv,
    float2 d_uv0,
    float2 d_uv1,
    half v0,
    half v1,
    half guard_m,
    half t,
    half global_alpha,
    int is_anime)
{
    half w0 = (1.0h - t) * v0;
    half w1 = t * v1;
    half4 c0_warp = tex0.sample(kLinearClamp, uv + d_uv0);
    half4 c1_warp = tex1.sample(kLinearClamp, uv + d_uv1);
    half4 mc = (w0 * c0_warp + w1 * c1_warp) / max(w0 + w1, 1e-3h);

    half4 c0_orig = tex0.sample(kLinearClamp, uv);
    half4 c1_orig = tex1.sample(kLinearClamp, uv);

    // Safe reference pixel:
    // For anime or high local edge contrast, snap toward nearest frame so ink lines never double;
    // otherwise smooth cross-dissolve.
    half4 nearest = (t < 0.5h) ? c0_orig : c1_orig;
    half4 linear_blend = mix(c0_orig, c1_orig, t);
    half edge_diff = fabs(c0_orig.r - c1_orig.r);
    half snap_w = (is_anime != 0) ? clamp(edge_diff * 8.0h, 0.35h, 1.0h) : clamp(edge_diff * 4.0h, 0.0h, 0.85h);
    half4 safe_px = mix(linear_blend, nearest, snap_w);

    half total_guard = clamp(guard_m + global_alpha * (1.0h - guard_m), 0.0h, 1.0h);
    return mix(mc, safe_px, total_guard);
}

kernel void synth_biplanar_yuv(
    texture2d<half, access::sample> Y0 [[texture(0)]],
    texture2d<half, access::sample> UV0 [[texture(1)]],
    texture2d<half, access::sample> Y1 [[texture(2)]],
    texture2d<half, access::sample> UV1 [[texture(3)]],
    texture2d<half, access::sample> Ft_tex [[texture(4)]],
    texture2d<half, access::sample> vc_tex [[texture(5)]],
    texture2d<half, access::write> out_Y [[texture(6)]],
    texture2d<half, access::write> out_UV [[texture(7)]],
    constant SynthParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.y_size.x || gid.y >= p.y_size.y) return;

    float2 uv = (float2(gid) + 0.5f) / float2(p.y_size);
    half t = half(p.phase_t);
    half g_alpha = half(p.global_fallback_alpha);

    // Letterbox protection: pure passthrough in black bars
    if (int(gid.y) < p.letterbox_top || int(gid.y) >= p.letterbox_bottom) {
        half y_val = (t < 0.5h) ? Y0.sample(kLinearClamp, uv).r : Y1.sample(kLinearClamp, uv).r;
        out_Y.write(half4(y_val, 0.0h, 0.0h, 1.0h), gid);
        if ((gid.x & 1u) == 0u && (gid.y & 1u) == 0u) {
            uint2 uv_gid = gid >> 1;
            if (uv_gid.x < p.uv_size.x && uv_gid.y < p.uv_size.y) {
                half2 c_val = (t < 0.5h) ? UV0.sample(kLinearClamp, uv).rg : UV1.sample(kLinearClamp, uv).rg;
                out_UV.write(half4(c_val.x, c_val.y, 0.0h, 1.0h), uv_gid);
            }
        }
        return;
    }

    half4 ft = Ft_tex.sample(kLinearClamp, uv);
    half4 vc = vc_tex.sample(kLinearClamp, uv);
    float2 d_uv0 = float2(ft.rg);
    float2 d_uv1 = float2(ft.ba);

    half4 y_out = sample_warped_guarded(Y0, Y1, uv, d_uv0, d_uv1, vc.r, vc.g, vc.b, t, g_alpha, p.is_anime_preset);

    // Optional debug HUD bar at top-left (height 10px, width 240px) showing tier & confidence
    if (p.debug_osd != 0 && gid.y >= 16 && gid.y < 26 && gid.x >= 16 && gid.x < 256) {
        float bar_x = float(gid.x - 16) / 240.0f;
        y_out.r = (bar_x < float(vc.a)) ? 0.85h : 0.20h;
    }

    out_Y.write(half4(y_out.r, 0.0h, 0.0h, 1.0h), gid);

    if ((gid.x & 1u) == 0u && (gid.y & 1u) == 0u) {
        uint2 uv_gid = gid >> 1;
        if (uv_gid.x < p.uv_size.x && uv_gid.y < p.uv_size.y) {
            float2 uv_c = (float2(uv_gid) + 0.5f) / float2(p.uv_size);
            half4 uv_out = sample_warped_guarded(UV0, UV1, uv_c, d_uv0, d_uv1, vc.r, vc.g, vc.b, t, g_alpha, p.is_anime_preset);
            out_UV.write(half4(uv_out.r, uv_out.g, 0.0h, 1.0h), uv_gid);
        }
    }
}

// 10b. Occlusion-Aware + Artifact-Guarded Synthesis for BGRA
kernel void synth_bgra(
    texture2d<half, access::sample> BGRA0 [[texture(0)]],
    texture2d<half, access::sample> BGRA1 [[texture(1)]],
    texture2d<half, access::sample> Ft_tex [[texture(2)]],
    texture2d<half, access::sample> vc_tex [[texture(3)]],
    texture2d<half, access::write> out_BGRA [[texture(4)]],
    constant SynthParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.y_size.x || gid.y >= p.y_size.y) return;
    float2 uv = (float2(gid) + 0.5f) / float2(p.y_size);
    half t = half(p.phase_t);
    half g_alpha = half(p.global_fallback_alpha);

    half4 ft = Ft_tex.sample(kLinearClamp, uv);
    half4 vc = vc_tex.sample(kLinearClamp, uv);
    half4 c_out = sample_warped_guarded(BGRA0, BGRA1, uv, float2(ft.rg), float2(ft.ba),
                                        vc.r, vc.g, vc.b, t, g_alpha, p.is_anime_preset);
    out_BGRA.write(c_out, gid);
}

// 11. Fast Linear Blend Baseline (for MF_BACKEND_BLEND / Q0 fallback)
kernel void blend_biplanar_yuv(
    texture2d<half, access::sample> Y0 [[texture(0)]],
    texture2d<half, access::sample> UV0 [[texture(1)]],
    texture2d<half, access::sample> Y1 [[texture(2)]],
    texture2d<half, access::sample> UV1 [[texture(3)]],
    texture2d<half, access::write> out_Y [[texture(4)]],
    texture2d<half, access::write> out_UV [[texture(5)]],
    constant SynthParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.y_size.x || gid.y >= p.y_size.y) return;
    float2 uv = (float2(gid) + 0.5f) / float2(p.y_size);
    half t = half(p.phase_t);

    half y0 = Y0.sample(kLinearClamp, uv).r;
    half y1 = Y1.sample(kLinearClamp, uv).r;
    out_Y.write(half4(mix(y0, y1, t), 0.0h, 0.0h, 1.0h), gid);

    if ((gid.x & 1u) == 0u && (gid.y & 1u) == 0u) {
        uint2 uv_gid = gid >> 1;
        if (uv_gid.x < p.uv_size.x && uv_gid.y < p.uv_size.y) {
            float2 uv_c = (float2(uv_gid) + 0.5f) / float2(p.uv_size);
            half2 c0 = UV0.sample(kLinearClamp, uv_c).rg;
            half2 c1 = UV1.sample(kLinearClamp, uv_c).rg;
            half2 cm = mix(c0, c1, t);
            out_UV.write(half4(cm.x, cm.y, 0.0h, 1.0h), uv_gid);
        }
    }
}

// 12. Color Space Conversion for Apple VTFrameRateConversion (YUV <-> RGBA16Float + Artifact Guard)
// Preserves full precision by storing normalized Y, Cb, Cr directly in R, G, B channels of RGhA
// (or linear BT.709 RGB), and converting back with Artifact Guard applied!
kernel void yuv_to_rgba16f(
    texture2d<half, access::sample> Y_in [[texture(0)]],
    texture2d<half, access::sample> UV_in [[texture(1)]],
    texture2d<half, access::write> RGBA_out [[texture(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint w = RGBA_out.get_width();
    uint h = RGBA_out.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float2 uv = (float2(gid) + 0.5f) / float2(w, h);
    half y = Y_in.sample(kLinearClamp, uv).r;
    half2 cbcr = UV_in.sample(kLinearClamp, uv).rg - half2(0.5h, 0.5h);

    // BT.709 YCbCr -> RGB in half float (unclamped so super-whites/HDR pass cleanly)
    half r = y + 1.5748h * cbcr.y;
    half g = y - 0.1873h * cbcr.x - 0.4681h * cbcr.y;
    half b = y + 1.8556h * cbcr.x;

    RGBA_out.write(half4(r, g, b, 1.0h), gid);
}

kernel void rgba16f_to_yuv_guarded(
    texture2d<half, access::sample> FRC_rgba [[texture(0)]],
    texture2d<half, access::sample> Y0 [[texture(1)]],
    texture2d<half, access::sample> UV0 [[texture(2)]],
    texture2d<half, access::sample> Y1 [[texture(3)]],
    texture2d<half, access::sample> UV1 [[texture(4)]],
    texture2d<half, access::sample> vc_tex [[texture(5)]],
    texture2d<half, access::write> out_Y [[texture(6)]],
    texture2d<half, access::write> out_UV [[texture(7)]],
    constant SynthParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.y_size.x || gid.y >= p.y_size.y) return;
    float2 uv = (float2(gid) + 0.5f) / float2(p.y_size);
    half t = half(p.phase_t);

    half4 rgb = FRC_rgba.sample(kLinearClamp, uv);
    half y_frc = 0.2126h * rgb.r + 0.7152h * rgb.g + 0.0722h * rgb.b;

    half4 vc = vc_tex.sample(kLinearClamp, uv);
    half guard_m = clamp(vc.b + half(p.global_fallback_alpha) * (1.0h - vc.b), 0.0h, 1.0h);
    if (int(gid.y) < p.letterbox_top || int(gid.y) >= p.letterbox_bottom) {
        guard_m = 1.0h;
    }

    half y0 = Y0.sample(kLinearClamp, uv).r;
    half y1 = Y1.sample(kLinearClamp, uv).r;
    half y_safe = (p.is_anime_preset != 0) ? ((t < 0.5h) ? y0 : y1) : mix(y0, y1, t);
    out_Y.write(half4(mix(y_frc, y_safe, guard_m), 0.0h, 0.0h, 1.0h), gid);

    if ((gid.x & 1u) == 0u && (gid.y & 1u) == 0u) {
        uint2 uv_gid = gid >> 1;
        if (uv_gid.x < p.uv_size.x && uv_gid.y < p.uv_size.y) {
            float2 uv_c = (float2(uv_gid) + 0.5f) / float2(p.uv_size);
            half4 rgb_c = FRC_rgba.sample(kLinearClamp, uv_c);
            half y_c = 0.2126h * rgb_c.r + 0.7152h * rgb_c.g + 0.0722h * rgb_c.b;
            half cb_frc = (rgb_c.b - y_c) * (1.0h / 1.8556h) + 0.5h;
            half cr_frc = (rgb_c.r - y_c) * (1.0h / 1.5748h) + 0.5h;

            half2 c0 = UV0.sample(kLinearClamp, uv_c).rg;
            half2 c1 = UV1.sample(kLinearClamp, uv_c).rg;
            half2 c_safe = (p.is_anime_preset != 0) ? ((t < 0.5h) ? c0 : c1) : mix(c0, c1, t);
            half2 c_out = mix(half2(cb_frc, cr_frc), c_safe, guard_m);
            out_UV.write(half4(c_out.x, c_out.y, 0.0h, 1.0h), uv_gid);
        }
    }
}
)MSL";

} // namespace macframe
