# MacFrame Algorithm & Artifact Guard Design

## 1. Preprocessing & Multi-Scale Luma Pyramid
Each incoming `CVPixelBufferRef` (`NV12`, `P010`, or `BGRA`) is bound zero-copy via `CVMetalTextureCache`. A $3\times 3$ noise-suppressing filter extracts normalized Luma into `pyr[0]` (`R16Float`), followed by 5 stages of $2\times$ Gaussian downsampling (`pyr[1..5]`).

## 2. Coarse Pair Analysis
At pyramid level 2 ($1/4$ resolution), `analyze_pair_coarse` computes:
- **Global & max-block absolute difference**: Identifies duplicate frames in 2s/3s animation (`mean_diff < 0.0028` and `max_block_diff < 0.0115`).
- **32-bin Luma histogram L1 distance**: Detects hard scene cuts and flashes (`is_scene_cut`).
- **Row Luma & gradient profile**: Detects top and bottom cinemascope letterbox bars (`letterbox_top`, `letterbox_bottom`).
- **Temporal Static Overlay Mask (`update_static_mask`)**: Tracks high-gradient pixels with near-zero temporal difference over consecutive frames to lock HUDs, logos, scoreboards, and burned-in subtitles.

## 3. MF-Flow Hierarchical Motion Estimation
From coarsest level down to `me_base`:
1. **3DRS + Diamond Search (`me_hierarchical_search`)**: Evaluates zero motion `(0,0)`, upsampled parent flow, 4 spatial neighbors, and temporal predictor using a **Zero-Mean + Spatial Gradient** patch cost:
   $$\text{Cost}(x, v) = (1 - \alpha_g)\sum |(I_0 - \bar{I}_0) - (I_1 - \bar{I}_1)| + \alpha_g \sum \|\nabla I_0 - \nabla I_1\|_1 + \lambda \|v - v_{\text{prior}}\|_2$$
2. **Edge-Aware Bilateral Smoothing (`flow_bilateral_smooth`)**: Regularizes vectors weighted by local Luma similarity and matching confidence.
3. **DIS Sub-Pixel Refinement (`flow_refine_dis`)**: Solves a $2\times 2$ structure-tensor Gauss-Newton update over $3\times 3$ windows for sub-pixel precision ($\text{EPE} < 0.07\text{ px}$).

## 4. Consistency, Visibility & Artifact Guard
Forward ($F_{01}$) and backward ($F_{10}$) flows are cross-checked:
$$e_{01}(x) = \|F_{01}(x) + F_{10}(x + F_{01}(x))\|_2, \quad e_{10}(x) = \|F_{10}(x) + F_{01}(x + F_{10}(x))\|_2$$
Visibility weights $(v_0, v_1)$ and confidence $C(x) \in [0, 1]$ drive both occlusion-aware warping and a spatially/temporally smoothed fallback mask $m(x)$ that blends toward the safest original frame in low-confidence regions.
