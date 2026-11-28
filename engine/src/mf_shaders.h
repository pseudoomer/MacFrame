// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

namespace macframe {

static const char *kMacFrameShaderSource = R"MSL(
#include <metal_stdlib>
#include <metal_simdgroup>
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

// 3. Pair Analysis on Coarse Pyramid (SIMD + Threadgroup Reduced)
struct PairAnalysisResult {
    atomic_uint diff_sum_fixed;
    atomic_uint max_block_diff;
    atomic_uint grad_sum_fixed;
    atomic_uint hist0[32];
    atomic_uint hist1[32];
    atomic_uint row_luma_sum[512];
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
    threadgroup atomic_uint local_hist0[32];
    threadgroup atomic_uint local_hist1[32];

    uint local_id = lid.y * tg_size.x + lid.x;
    if (local_id == 0u) {
        atomic_store_explicit(&local_diff_sum, 0u, memory_order_relaxed);
        atomic_store_explicit(&local_grad_sum, 0u, memory_order_relaxed);
    }
    if (local_id < 32u) {
        atomic_store_explicit(&local_hist0[local_id], 0u, memory_order_relaxed);
        atomic_store_explicit(&local_hist1[local_id], 0u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    uint d_fixed = 0u;
    uint g_fixed = 0u;
    if (gid.x < w && gid.y < h) {
        half v0 = luma0.read(gid).r;
        half v1 = luma1.read(gid).r;
        half rx = (gid.x + 1 < w) ? luma0.read(gid + uint2(1, 0)).r : v0;
        half ry = (gid.y + 1 < h) ? luma0.read(gid + uint2(0, 1)).r : v0;
        float gx = float(fabs(rx - v0) + fabs(ry - v0));
        float d  = float(fabs(v0 - v1));

        d_fixed = uint(clamp(d * 1024.0f, 0.0f, 1024.0f));
        g_fixed = uint(clamp(gx * 1024.0f, 0.0f, 2048.0f));

        uint b0 = min(uint(clamp(float(v0), 0.0f, 0.999f) * 32.0f), 31u);
        uint b1 = min(uint(clamp(float(v1), 0.0f, 0.999f) * 32.0f), 31u);
        atomic_fetch_add_explicit(&local_hist0[b0], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&local_hist1[b1], 1u, memory_order_relaxed);

        if (gid.y < 512) {
            uint luma_fixed = uint(clamp(float(max(v0, v1)) * 1024.0f, 0.0f, 1024.0f));
            atomic_fetch_add_explicit(&res->row_luma_sum[gid.y], luma_fixed, memory_order_relaxed);
            atomic_fetch_add_explicit(&res->row_grad_sum[gid.y], g_fixed, memory_order_relaxed);
        }
    }

    uint sg_d = simd_sum(d_fixed);
    uint sg_g = simd_sum(g_fixed);
    if (simd_is_first()) {
        if (sg_d) atomic_fetch_add_explicit(&local_diff_sum, sg_d, memory_order_relaxed);
        if (sg_g) atomic_fetch_add_explicit(&local_grad_sum, sg_g, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (local_id < 32u) {
        uint h0 = atomic_load_explicit(&local_hist0[local_id], memory_order_relaxed);
        uint h1 = atomic_load_explicit(&local_hist1[local_id], memory_order_relaxed);
        if (h0) atomic_fetch_add_explicit(&res->hist0[local_id], h0, memory_order_relaxed);
        if (h1) atomic_fetch_add_explicit(&res->hist1[local_id], h1, memory_order_relaxed);
    }
    if (local_id == 0u) {
        uint block_px = tg_size.x * tg_size.y;
        uint d_sum = atomic_load_explicit(&local_diff_sum, memory_order_relaxed);
        uint g_sum = atomic_load_explicit(&local_grad_sum, memory_order_relaxed);
        uint block_avg = d_sum / max(block_px, 1u);
        if (d_sum) atomic_fetch_add_explicit(&res->diff_sum_fixed, d_sum, memory_order_relaxed);
        if (g_sum) atomic_fetch_add_explicit(&res->grad_sum_fixed, g_sum, memory_order_relaxed);
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

    half c0 = luma0.sample(kLinearClamp, uv).r;
    half c1 = luma1.sample(kLinearClamp, uv).r;
    half diff = fabs(c0 - c1);

    half l = luma0.sample(kLinearClamp, uv + float2(-inv.x, 0.0f)).r;
    half r = luma0.sample(kLinearClamp, uv + float2( inv.x, 0.0f)).r;
    half u = luma0.sample(kLinearClamp, uv + float2(0.0f, -inv.y)).r;
    half d = luma0.sample(kLinearClamp, uv + float2(0.0f,  inv.y)).r;
    half edge = fabs(r - l) + fabs(d - u);

    half prev = prev_static.read(gid).r;
    half next_val = 0.0h;
    if (diff < 0.0055h && edge > 0.035h) {
        next_val = min(prev + 0.25h, 1.0h);
    } else if (diff < 0.0085h) {
        next_val = prev * 0.85h;
    }
    next_static.write(half4(next_val, 0.0h, 0.0h, 1.0h), gid);
}

// 5. Hierarchical Motion Estimation (FP16 ALU + Static Early Exit)
struct MESearchParams {
    uint2 size;
    float2 inv_size;
    float grad_weight;
    float smooth_lambda;
    int search_radius;
    int is_coarsest;
    int use_static_early_exit;
};

static inline float patch_cost(
    texture2d<half, access::sample> I0,
    texture2d<half, access::sample> I1,
    float2 pos,
    float2 mv,
    float2 inv_size,
    half grad_weight)
{
    const float2 offsets[9] = {
        float2( 0.0f,  0.0f),
        float2(-2.0f,  0.0f), float2( 2.0f,  0.0f),
        float2( 0.0f, -2.0f), float2( 0.0f,  2.0f),
        float2(-1.0f, -1.0f), float2( 1.0f, -1.0f),
        float2(-1.0f,  1.0f), float2( 1.0f,  1.0f)
    };

    half v0[9], v1[9];
    half sum0 = 0.0h, sum1 = 0.0h;
    float2 base0 = pos * inv_size;
    float2 base1 = (pos + mv) * inv_size;
    for (int i = 0; i < 9; ++i) {
        float2 duv = offsets[i] * inv_size;
        v0[i] = I0.sample(kLinearClamp, base0 + duv).r;
        v1[i] = I1.sample(kLinearClamp, base1 + duv).r;
        sum0 += v0[i];
        sum1 += v1[i];
    }
    half mean_diff = (sum0 - sum1) * (1.0h / 9.0h) * 0.65h;

    half sad = 0.0h;
    for (int i = 0; i < 9; ++i) {
        half diff = v0[i] - v1[i];
        half raw_d = fabs(diff);
        half zm_d  = fabs(diff - mean_diff);
        sad += min(raw_d, zm_d + 0.004h);
    }

    half gx0 = v0[2] - v0[1], gx1 = v1[2] - v1[1];
    half gy0 = v0[4] - v0[3], gy1 = v1[4] - v1[3];
    half gd1 = (v0[8] - v0[5]) - (v1[8] - v1[5]);
    half gd2 = (v0[7] - v0[6]) - (v1[7] - v1[6]);
    half grad_err = (fabs(gx0 - gx1) + fabs(gy0 - gy1) + fabs(gd1) + fabs(gd2)) * 2.25h;

    return float((1.0h - grad_weight) * sad + grad_weight * grad_err);
}

kernel void me_hierarchical_search(
    texture2d<half, access::sample> I0 [[texture(0)]],
    texture2d<half, access::sample> I1 [[texture(1)]],
    texture2d<half, access::sample> prev_level_flow [[texture(2)]],
    texture2d<half, access::sample> temporal_flow [[texture(3)]],
    texture2d<half, access::sample> static_mask [[texture(4)]],
    texture2d<half, access::write> out_flow [[texture(5)]],
    constant MESearchParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.size.x || gid.y >= p.size.y) return;

    float2 pos = float2(gid) + 0.5f;
    float2 uv = pos * p.inv_size;
    half gw = half(p.grad_weight);

    float2 best_mv = float2(0.0f, 0.0f);
    float2 prior_mv = float2(0.0f, 0.0f);

    if (p.is_coarsest == 0) {
        prior_mv = float2(prev_level_flow.sample(kLinearClamp, uv).rg) * 2.0f;
    }

    float zero_cost = patch_cost(I0, I1, pos, best_mv, p.inv_size, gw);
    if (p.use_static_early_exit != 0) {
        half sw = static_mask.sample(kLinearClamp, uv).r;
        if (sw > 0.80h && zero_cost < 0.0025f) {
            out_flow.write(half4(0.0h, 0.0h, half(zero_cost), 0.0h), gid);
            return;
        }
    }

    float best_cost = zero_cost + p.smooth_lambda * length(best_mv - prior_mv);

    auto test_candidate = [&](float2 cand) {
        float c = patch_cost(I0, I1, pos, cand, p.inv_size, gw)
                + p.smooth_lambda * length(cand - prior_mv);
        if (c < best_cost) {
            best_cost = c;
            best_mv = cand;
        }
    };

    if (p.is_coarsest == 0) {
        test_candidate(prior_mv);
        float2 step_uv = p.inv_size * 4.0f;
        test_candidate(float2(prev_level_flow.sample(kLinearClamp, uv + float2(-step_uv.x, 0.0f)).rg) * 2.0f);
        test_candidate(float2(prev_level_flow.sample(kLinearClamp, uv + float2( step_uv.x, 0.0f)).rg) * 2.0f);
        test_candidate(float2(prev_level_flow.sample(kLinearClamp, uv + float2(0.0f, -step_uv.y)).rg) * 2.0f);
        test_candidate(float2(prev_level_flow.sample(kLinearClamp, uv + float2(0.0f,  step_uv.y)).rg) * 2.0f);
    }

    float2 temp_mv = float2(temporal_flow.sample(kLinearClamp, uv).rg);
    test_candidate(temp_mv);

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

// 6. Edge-Aware Bilateral Flow Smoothing (FP16 fast::exp)
kernel void flow_bilateral_smooth(
    texture2d<half, access::read> I0 [[texture(0)]],
    texture2d<half, access::read> in_flow [[texture(1)]],
    texture2d<half, access::write> out_flow [[texture(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint w = in_flow.get_width();
    uint h = in_flow.get_height();
    if (gid.x >= w || gid.y >= h) return;

    half c_luma = I0.read(gid).r;
    half4 center_f = in_flow.read(gid);
    float2 sum_mv = float2(0.0f);
    float sum_w = 0.0f;

    for (int dy = -1; dy <= 1; ++dy) {
        int ny = clamp(int(gid.y) + dy, 0, int(h) - 1);
        for (int dx = -1; dx <= 1; ++dx) {
            int nx = clamp(int(gid.x) + dx, 0, int(w) - 1);
            uint2 np = uint2(nx, ny);
            half nl = I0.read(np).r;
            half4 nf = in_flow.read(np);

            float w_luma = fast::exp(-float(fabs(nl - c_luma)) * 18.0f);
            float w_cost = fast::exp(-float(nf.b) * 2.5f);
            float w_sp   = (dx == 0 && dy == 0) ? 2.0f : 1.0f;
            float weight = w_luma * w_cost * w_sp + 1e-4f;

            sum_mv += float2(nf.rg) * weight;
            sum_w  += weight;
        }
    }

    float2 smoothed = sum_mv / sum_w;
    out_flow.write(half4(half2(smoothed), center_f.b, 0.0h), gid);
}

// 7. DIS Sub-Pixel Optical Flow Refinement
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

    float s_xx = 1e-3f, s_xy = 0.0f, s_yy = 1e-3f;
    float b_x = 0.0f, b_y = 0.0f;

    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            float2 p0 = (pos + float2(dx, dy)) * inv_size;
            float2 p1 = (pos + mv + float2(dx, dy)) * inv_size;

            half i0 = I0.sample(kLinearClamp, p0).r;
            half i1 = I1.sample(kLinearClamp, p1).r;
            float it = float(i1 - i0);

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
        float len = length(delta);
        if (len > 0.75f) {
            delta *= (0.75f / len);
        }
        mv += delta;
    }

    out_flow.write(half4(half2(mv), f_in.b, 0.0h), gid);
}

// 8. Forward-Backward Consistency, Visibility, Confidence & Static/Letterbox Clamping (SIMD Reduced)
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
    atomic_uint conf_sum_fixed;
    atomic_uint fallback_pixels;
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
    texture2d<half, access::write> out_vis_conf [[texture(8)]],
    device ConfidenceStats *stats [[buffer(0)]],
    constant ConsistencyParams &p [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 lid [[thread_position_in_threadgroup]],
    uint2 tg_size [[threads_per_threadgroup]])
{
    uint my_conf = 0u;
    uint my_fb   = 0u;

    if (gid.x < p.size.x && gid.y < p.size.y) {
        float2 pos = float2(gid) + 0.5f;
        float2 uv = pos * p.inv_size;

        bool in_letterbox = (int(gid.y) < p.letterbox_top_me) || (int(gid.y) >= p.letterbox_bottom_me);
        float static_w = (p.static_lock != 0) ? float(static_mask_tex.sample(kLinearClamp, uv).r) : 0.0f;

        if (in_letterbox || static_w > 0.72f) {
            out_F01_clean.write(half4(0.0h), gid);
            out_F10_clean.write(half4(0.0h), gid);
            out_vis_conf.write(half4(1.0h, 1.0h, 0.0h, 1.0h), gid);
            my_conf = 1024u;
        } else {
            float2 f01 = float2(F01_tex.sample(kLinearClamp, uv).rg) * (1.0f - static_w);
            float2 f10 = (p.bidirectional != 0)
                ? float2(F10_tex.sample(kLinearClamp, uv).rg) * (1.0f - static_w)
                : -f01;

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

            float2 f_r = float2(F01_tex.sample(kLinearClamp, uv + float2(p.inv_size.x, 0.0f)).rg);
            float2 f_d = float2(F01_tex.sample(kLinearClamp, uv + float2(0.0f, p.inv_size.y)).rg);
            float deform = length(f_r - f01) + length(f_d - f01);

            half i0 = I0.sample(kLinearClamp, uv).r;
            half i1_warped = I1.sample(kLinearClamp, dst01 * p.inv_size).r;
            half i0_warped = I0.sample(kLinearClamp, dst10 * p.inv_size).r;
            half i1 = I1.sample(kLinearClamp, uv).r;

            float photo01 = float(fabs(i0 - i1_warped));
            float photo10 = float(fabs(i1 - i0_warped));

            float v0 = fast::exp(-(err01 * err01) * 0.12f - photo01 * 6.0f) * (oob01 ? 0.05f : 1.0f);
            float v1 = fast::exp(-(err10 * err10) * 0.12f - photo10 * 6.0f) * (oob10 ? 0.05f : 1.0f);
            v0 = clamp(v0, 0.01f, 1.0f);
            v1 = clamp(v1, 0.01f, 1.0f);

            float min_err = min(err01, err10);
            float min_photo = min(photo01, photo10);
            float conf = fast::exp(-(min_err * min_err) * 0.08f - (min_photo * min_photo) * 18.0f - max(deform - 1.5f, 0.0f) * 0.25f);
            if (oob01 && oob10) conf *= 0.25f;
            conf = clamp(conf, 0.0f, 1.0f);

            float raw_guard = clamp((1.0f - conf) * p.guard_strength * 1.4f, 0.0f, 1.0f);
            float prev_guard = float(prev_guard_tex.read(gid).b);
            float guard_mask = clamp(0.72f * raw_guard + 0.28f * prev_guard, 0.0f, 1.0f);

            out_F01_clean.write(half4(half2(f01), 0.0h, 0.0h), gid);
            out_F10_clean.write(half4(half2(f10), 0.0h, 0.0h), gid);
            out_vis_conf.write(half4(half(v0), half(v1), half(guard_mask), half(conf)), gid);

            my_conf = uint(conf * 1024.0f);
            if (guard_mask > 0.25f) my_fb = 1u;
        }
    }

    uint sg_conf = simd_sum(my_conf);
    uint sg_fb   = simd_sum(my_fb);
    threadgroup atomic_uint tg_conf;
    threadgroup atomic_uint tg_fb;
    uint lid_flat = lid.y * tg_size.x + lid.x;
    if (lid_flat == 0u) {
        atomic_store_explicit(&tg_conf, 0u, memory_order_relaxed);
        atomic_store_explicit(&tg_fb, 0u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (simd_is_first()) {
        if (sg_conf) atomic_fetch_add_explicit(&tg_conf, sg_conf, memory_order_relaxed);
        if (sg_fb)   atomic_fetch_add_explicit(&tg_fb, sg_fb, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (lid_flat == 0u) {
        uint c_sum = atomic_load_explicit(&tg_conf, memory_order_relaxed);
        uint f_sum = atomic_load_explicit(&tg_fb, memory_order_relaxed);
        if (c_sum) atomic_fetch_add_explicit(&stats->conf_sum_fixed, c_sum, memory_order_relaxed);
        if (f_sum) atomic_fetch_add_explicit(&stats->fallback_pixels, f_sum, memory_order_relaxed);
    }
}

// 9. Intermediate Phase Flow Projection (t in (0, 1))
struct PhaseProjectParams {
    uint2 size;
    float2 inv_size;
    float phase_t;
    float flow_scale;
};

kernel void project_phase_flow(
    texture2d<half, access::sample> I0 [[texture(0)]],
    texture2d<half, access::sample> I1 [[texture(1)]],
    texture2d<half, access::sample> F01 [[texture(2)]],
    texture2d<half, access::sample> F10 [[texture(3)]],
    texture2d<half, access::sample> vis_conf [[texture(4)]],
    texture2d<half, access::write> out_Ft [[texture(5)]],
    texture2d<half, access::write> out_vc_smooth [[texture(6)]],
    constant PhaseProjectParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.size.x || gid.y >= p.size.y) return;

    float2 pos = float2(gid) + 0.5f;
    float t = p.phase_t;

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
    out_Ft.write(half4(half2(best_f0 * p.inv_size), half2(best_f1 * p.inv_size)), gid);
    out_vc_smooth.write(half4(vc_acc), gid);
}

// 10. Synthesis Params, A/B Split Helpers & HDR-Safe Overlays
struct SynthParams {
    uint2 y_size;
    uint2 uv_size;
    float phase_t;
    float global_fallback_alpha;
    int is_anime_preset;
    int letterbox_top;
    int letterbox_bottom;
    int debug_osd;
    int current_tier;
    int ab_mode;
    float ab_split;
    float overlay_hi;
    float overlay_lo;
    float kr;
    float kb;
    float y_offset;
    float y_scale;
    float c_offset;
    float c_scale;
};

static inline bool ab_is_original(uint2 px, constant SynthParams &p) {
    if (p.ab_mode == 1) return int(px.x) < int(float(p.y_size.x) * p.ab_split);
    if (p.ab_mode == 2) return int(px.x) >= int(float(p.y_size.x) * p.ab_split);
    if (p.ab_mode == 3) return int(px.y) < int(float(p.y_size.y) * p.ab_split);
    if (p.ab_mode == 4) return int(px.y) >= int(float(p.y_size.y) * p.ab_split);
    return false;
}

static inline bool ab_on_divider(uint2 px, constant SynthParams &p) {
    if (p.ab_mode == 1 || p.ab_mode == 2) {
        int sx = int(float(p.y_size.x) * p.ab_split);
        return abs(int(px.x) - sx) <= 1;
    }
    if (p.ab_mode == 3 || p.ab_mode == 4) {
        int sy = int(float(p.y_size.y) * p.ab_split);
        return abs(int(px.y) - sy) <= 1;
    }
    return false;
}

// 5x7 pixel bitmap glyphs for 'A' (orig) and 'B' (interp), scaled 2x -> 10x14
static inline int glyph_bit_AB(bool is_B, int gx, int gy) {
    // 5 cols x 7 rows encoded per row (MSB=col0 .. bit0=col4)
    const uint rowsA[7] = { 0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11 };
    const uint rowsB[7] = { 0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E };
    if (gx < 0 || gx >= 5 || gy < 0 || gy >= 7) return 0;
    uint r = is_B ? rowsB[gy] : rowsA[gy];
    return int((r >> (4 - gx)) & 1u);
}

// Returns 0 = none, 1 = pill bg, 2 = glyph fg
static inline int ab_badge_pixel(uint2 px, constant SynthParams &p) {
    if (p.ab_mode == 0) return 0;
    int sx = int(float(p.y_size.x) * p.ab_split);
    int sy = int(float(p.y_size.y) * p.ab_split);

    int2 originA, originB;
    if (p.ab_mode == 1) {
        originA = int2(max(8, sx - 28), 24);
        originB = int2(min(int(p.y_size.x) - 26, sx + 10), 24);
    } else if (p.ab_mode == 2) {
        originB = int2(max(8, sx - 28), 24);
        originA = int2(min(int(p.y_size.x) - 26, sx + 10), 24);
    } else if (p.ab_mode == 3) {
        originA = int2(24, max(8, sy - 28));
        originB = int2(24, min(int(p.y_size.y) - 30, sy + 10));
    } else {
        originB = int2(24, max(8, sy - 28));
        originA = int2(24, min(int(p.y_size.y) - 30, sy + 10));
    }

    int2 pA = int2(px) - originA;
    if (pA.x >= 0 && pA.x < 18 && pA.y >= 0 && pA.y < 22) {
        if (pA.x >= 4 && pA.x < 14 && pA.y >= 4 && pA.y < 18) {
            if (glyph_bit_AB(false, (pA.x - 4) >> 1, (pA.y - 4) >> 1)) return 2;
        }
        return 1;
    }
    int2 pB = int2(px) - originB;
    if (pB.x >= 0 && pB.x < 18 && pB.y >= 0 && pB.y < 22) {
        if (pB.x >= 4 && pB.x < 14 && pB.y >= 4 && pB.y < 18) {
            if (glyph_bit_AB(true, (pB.x - 4) >> 1, (pB.y - 4) >> 1)) return 2;
        }
        return 1;
    }
    return 0;
}

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

    half4 nearest = (t < 0.5h) ? c0_orig : c1_orig;
    half4 linear_blend = mix(c0_orig, c1_orig, t);
    half edge_diff = fabs(c0_orig.r - c1_orig.r);
    half snap_w = (is_anime != 0) ? clamp(edge_diff * 8.0h, 0.35h, 1.0h) : clamp(edge_diff * 4.0h, 0.0h, 0.85h);
    half4 safe_px = mix(linear_blend, nearest, snap_w);

    half total_guard = clamp(guard_m + global_alpha * (1.0h - guard_m), 0.0h, 1.0h);
    return mix(mc, safe_px, total_guard);
}

// 10a. 2x2 Quad Vectorized Synthesis for NV12 / P010 (4x fewer threads, zero UV divergence)
kernel void synth_biplanar_yuv_quad(
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
    uint2 px_base = gid << 1;
    if (px_base.x >= p.y_size.x || px_base.y >= p.y_size.y) return;

    float2 inv_y = 1.0f / float2(p.y_size);
    float2 uv_c = (float2(gid) + 0.5f) / float2(p.uv_size);
    half t = half(p.phase_t);
    half g_alpha = half(p.global_fallback_alpha);
    half hi_luma = half(p.overlay_hi);
    half lo_luma = half(p.overlay_lo);

    half4 ft = Ft_tex.sample(kLinearClamp, uv_c);
    half4 vc = vc_tex.sample(kLinearClamp, uv_c);
    float2 d_uv0 = float2(ft.rg);
    float2 d_uv1 = float2(ft.ba);

    const uint2 qoffs[4] = { uint2(0, 0), uint2(1, 0), uint2(0, 1), uint2(1, 1) };
    bool any_divider = false;
    bool quad_orig   = false;
    int  any_badge   = 0;

    for (int i = 0; i < 4; ++i) {
        uint2 px = px_base + qoffs[i];
        if (px.x >= p.y_size.x || px.y >= p.y_size.y) continue;
        float2 uv = (float2(px) + 0.5f) * inv_y;

        half y_val;
        if (int(px.y) < p.letterbox_top || int(px.y) >= p.letterbox_bottom) {
            y_val = (t < 0.5h) ? Y0.sample(kLinearClamp, uv).r : Y1.sample(kLinearClamp, uv).r;
        } else if (p.ab_mode != 0 && ab_is_original(px, p)) {
            y_val = Y0.sample(kLinearClamp, uv).r;
            if (i == 0) quad_orig = true;
        } else {
            y_val = sample_warped_guarded(Y0, Y1, uv, d_uv0, d_uv1, vc.r, vc.g, vc.b, t, g_alpha, p.is_anime_preset).r;
        }

        if (p.ab_mode != 0) {
            if (ab_on_divider(px, p)) {
                y_val = hi_luma;
                any_divider = true;
            } else {
                int b = ab_badge_pixel(px, p);
                if (b == 2) { y_val = hi_luma; any_badge = 2; }
                else if (b == 1) { y_val = mix(y_val, lo_luma, 0.72h); if (any_badge == 0) any_badge = 1; }
            }
        }

        if (p.debug_osd != 0 && px.y >= 16 && px.y < 26 && px.x >= 16 && px.x < 256) {
            float bar_x = float(px.x - 16) / 240.0f;
            y_val = (bar_x < float(vc.a)) ? hi_luma : lo_luma;
        }

        out_Y.write(half4(y_val, 0.0h, 0.0h, 1.0h), px);
    }

    if (gid.x < p.uv_size.x && gid.y < p.uv_size.y) {
        half2 c_val;
        if (int(px_base.y) < p.letterbox_top || int(px_base.y) >= p.letterbox_bottom) {
            c_val = (t < 0.5h) ? UV0.sample(kLinearClamp, uv_c).rg : UV1.sample(kLinearClamp, uv_c).rg;
        } else if (p.ab_mode != 0 && quad_orig) {
            c_val = UV0.sample(kLinearClamp, uv_c).rg;
        } else {
            c_val = sample_warped_guarded(UV0, UV1, uv_c, d_uv0, d_uv1, vc.r, vc.g, vc.b, t, g_alpha, p.is_anime_preset).rg;
        }

        if (any_divider || any_badge > 0) {
            c_val = half2(0.5h, 0.5h);
        }
        out_UV.write(half4(c_val.x, c_val.y, 0.0h, 1.0h), gid);
    }
}

// 10b. Legacy single-pixel biplanar kernel (kept for parity)
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
    if (p.debug_osd != 0 && gid.y >= 16 && gid.y < 26 && gid.x >= 16 && gid.x < 256) {
        float bar_x = float(gid.x - 16) / 240.0f;
        y_out.r = (bar_x < float(vc.a)) ? half(p.overlay_hi) : half(p.overlay_lo);
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

// 10c. Occlusion-Aware + Artifact-Guarded Synthesis for BGRA
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

    half4 c_out;
    if (p.ab_mode != 0 && ab_is_original(gid, p)) {
        c_out = BGRA0.sample(kLinearClamp, uv);
    } else {
        half4 ft = Ft_tex.sample(kLinearClamp, uv);
        half4 vc = vc_tex.sample(kLinearClamp, uv);
        c_out = sample_warped_guarded(BGRA0, BGRA1, uv, float2(ft.rg), float2(ft.ba),
                                      vc.r, vc.g, vc.b, t, g_alpha, p.is_anime_preset);
    }
    if (p.ab_mode != 0) {
        if (ab_on_divider(gid, p)) {
            c_out = half4(half3(half(p.overlay_hi)), 1.0h);
        } else {
            int b = ab_badge_pixel(gid, p);
            if (b == 2) c_out = half4(half3(half(p.overlay_hi)), 1.0h);
            else if (b == 1) c_out = mix(c_out, half4(half3(half(p.overlay_lo)), 1.0h), 0.72h);
        }
    }
    out_BGRA.write(c_out, gid);
}

// 11. Fast Linear Blend & A/B Passthrough Baseline (for MF_BACKEND_BLEND / Q0 / passthrough A/B)
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
    uint2 px_base = gid << 1;
    if (px_base.x >= p.y_size.x || px_base.y >= p.y_size.y) return;

    float2 inv_y = 1.0f / float2(p.y_size);
    float2 uv_c = (float2(gid) + 0.5f) / float2(p.uv_size);
    half t = half(p.phase_t);
    half hi_luma = half(p.overlay_hi);
    half lo_luma = half(p.overlay_lo);

    const uint2 qoffs[4] = { uint2(0, 0), uint2(1, 0), uint2(0, 1), uint2(1, 1) };
    bool any_divider = false;
    bool quad_orig   = false;
    int  any_badge   = 0;

    for (int i = 0; i < 4; ++i) {
        uint2 px = px_base + qoffs[i];
        if (px.x >= p.y_size.x || px.y >= p.y_size.y) continue;
        float2 uv = (float2(px) + 0.5f) * inv_y;

        half y0 = Y0.sample(kLinearClamp, uv).r;
        half y_val;
        if (p.ab_mode != 0 && ab_is_original(px, p)) {
            y_val = y0;
            if (i == 0) quad_orig = true;
        } else {
            half y1 = Y1.sample(kLinearClamp, uv).r;
            y_val = mix(y0, y1, t);
        }

        if (p.ab_mode != 0) {
            if (ab_on_divider(px, p)) {
                y_val = hi_luma;
                any_divider = true;
            } else {
                int b = ab_badge_pixel(px, p);
                if (b == 2) { y_val = hi_luma; any_badge = 2; }
                else if (b == 1) { y_val = mix(y_val, lo_luma, 0.72h); if (any_badge == 0) any_badge = 1; }
            }
        }
        if (p.debug_osd != 0 && px.y >= 16 && px.y < 26 && px.x >= 16 && px.x < 256) {
            float bar_x = float(px.x - 16) / 240.0f;
            y_val = (bar_x < 0.5f) ? hi_luma : lo_luma;
        }
        out_Y.write(half4(y_val, 0.0h, 0.0h, 1.0h), px);
    }

    if (gid.x < p.uv_size.x && gid.y < p.uv_size.y) {
        half2 c0 = UV0.sample(kLinearClamp, uv_c).rg;
        half2 c_val;
        if (p.ab_mode != 0 && quad_orig) {
            c_val = c0;
        } else {
            half2 c1 = UV1.sample(kLinearClamp, uv_c).rg;
            c_val = mix(c0, c1, t);
        }
        if (any_divider || any_badge > 0) {
            c_val = half2(0.5h, 0.5h);
        }
        out_UV.write(half4(c_val.x, c_val.y, 0.0h, 1.0h), gid);
    }
}

// 12. Color Space Conversion for Apple VTFrameRateConversion (BT.709 / BT.2020 / Video & Full Range)
struct ColorMatrixParams {
    float kr;
    float kb;
    float y_offset;
    float y_scale;
    float c_offset;
    float c_scale;
    float overlay_hi;
    float overlay_lo;
};

kernel void yuv_to_rgba16f(
    texture2d<half, access::sample> Y_in [[texture(0)]],
    texture2d<half, access::sample> UV_in [[texture(1)]],
    texture2d<half, access::write> RGBA_out [[texture(2)]],
    constant ColorMatrixParams &cm [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint w = RGBA_out.get_width();
    uint h = RGBA_out.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float2 uv = (float2(gid) + 0.5f) / float2(w, h);
    float y_raw = float(Y_in.sample(kLinearClamp, uv).r);
    float2 c_raw = float2(UV_in.sample(kLinearClamp, uv).rg);

    float y  = (y_raw - cm.y_offset) * cm.y_scale;
    float cb = (c_raw.x - cm.c_offset) * cm.c_scale;
    float cr = (c_raw.y - cm.c_offset) * cm.c_scale;

    float kr = cm.kr;
    float kb = cm.kb;
    float kg = 1.0f - kr - kb;

    float r = y + 2.0f * (1.0f - kr) * cr;
    float b = y + 2.0f * (1.0f - kb) * cb;
    float g = y - (2.0f * kb * (1.0f - kb) / kg) * cb - (2.0f * kr * (1.0f - kr) / kg) * cr;

    RGBA_out.write(half4(half(r), half(g), half(b), 1.0h), gid);
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
    uint2 px_base = gid << 1;
    if (px_base.x >= p.y_size.x || px_base.y >= p.y_size.y) return;

    float2 inv_y = 1.0f / float2(p.y_size);
    float2 uv_c = (float2(gid) + 0.5f) / float2(p.uv_size);
    float t = p.phase_t;
    float kr = p.kr;
    float kb = p.kb;
    float kg = 1.0f - kr - kb;
    float inv_y_scale = 1.0f / p.y_scale;
    float inv_c_scale = 1.0f / p.c_scale;
    half hi_luma = half(p.overlay_hi);
    half lo_luma = half(p.overlay_lo);

    half4 vc_c = vc_tex.sample(kLinearClamp, uv_c);
    float guard_m = clamp(float(vc_c.b) + p.global_fallback_alpha * (1.0f - float(vc_c.b)), 0.0f, 1.0f);
    if (int(px_base.y) < p.letterbox_top || int(px_base.y) >= p.letterbox_bottom) {
        guard_m = 1.0f;
    }

    const uint2 qoffs[4] = { uint2(0, 0), uint2(1, 0), uint2(0, 1), uint2(1, 1) };
    bool any_divider = false;
    bool quad_orig   = false;
    int  any_badge   = 0;

    for (int i = 0; i < 4; ++i) {
        uint2 px = px_base + qoffs[i];
        if (px.x >= p.y_size.x || px.y >= p.y_size.y) continue;
        float2 uv = (float2(px) + 0.5f) * inv_y;

        half y_val;
        if (p.ab_mode != 0 && ab_is_original(px, p)) {
            y_val = Y0.sample(kLinearClamp, uv).r;
            if (i == 0) quad_orig = true;
        } else {
            float3 rgb = float3(FRC_rgba.sample(kLinearClamp, uv).rgb);
            float y_lin = kr * rgb.r + kg * rgb.g + kb * rgb.b;
            float y_frc = y_lin * inv_y_scale + p.y_offset;

            float y0 = float(Y0.sample(kLinearClamp, uv).r);
            float y1 = float(Y1.sample(kLinearClamp, uv).r);
            float y_safe = (p.is_anime_preset != 0) ? ((t < 0.5f) ? y0 : y1) : mix(y0, y1, t);
            y_val = half(mix(y_frc, y_safe, guard_m));
        }

        if (p.ab_mode != 0) {
            if (ab_on_divider(px, p)) {
                y_val = hi_luma;
                any_divider = true;
            } else {
                int b = ab_badge_pixel(px, p);
                if (b == 2) { y_val = hi_luma; any_badge = 2; }
                else if (b == 1) { y_val = mix(y_val, lo_luma, 0.72h); if (any_badge == 0) any_badge = 1; }
            }
        }
        if (p.debug_osd != 0 && px.y >= 16 && px.y < 26 && px.x >= 16 && px.x < 256) {
            float bar_x = float(px.x - 16) / 240.0f;
            y_val = (bar_x < float(vc_c.a)) ? hi_luma : lo_luma;
        }
        out_Y.write(half4(y_val, 0.0h, 0.0h, 1.0h), px);
    }

    if (gid.x < p.uv_size.x && gid.y < p.uv_size.y) {
        half2 c_out;
        if (p.ab_mode != 0 && quad_orig) {
            c_out = UV0.sample(kLinearClamp, uv_c).rg;
        } else {
            float3 rgb_c = float3(FRC_rgba.sample(kLinearClamp, uv_c).rgb);
            float y_c = kr * rgb_c.r + kg * rgb_c.g + kb * rgb_c.b;
            float cb_frc = ((rgb_c.b - y_c) / (2.0f * (1.0f - kb))) * inv_c_scale + p.c_offset;
            float cr_frc = ((rgb_c.r - y_c) / (2.0f * (1.0f - kr))) * inv_c_scale + p.c_offset;

            float2 c0 = float2(UV0.sample(kLinearClamp, uv_c).rg);
            float2 c1 = float2(UV1.sample(kLinearClamp, uv_c).rg);
            float2 c_safe = (p.is_anime_preset != 0) ? ((t < 0.5f) ? c0 : c1) : mix(c0, c1, t);
            c_out = half2(mix(float2(cb_frc, cr_frc), c_safe, guard_m));
        }
        if (any_divider || any_badge > 0) {
            c_out = half2(0.5h, 0.5h);
        }
        out_UV.write(half4(c_out.x, c_out.y, 0.0h, 1.0h), gid);
    }
}
)MSL";

} // namespace macframe
