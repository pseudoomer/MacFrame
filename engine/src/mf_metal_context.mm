// SPDX-License-Identifier: GPL-3.0-or-later
#include "mf_metal_context.hpp"
#include "mf_shaders.h"
#import <Foundation/Foundation.h>

namespace macframe {

MetalContext &MetalContext::shared() {
    static MetalContext instance;
    return instance;
}

MetalContext::MetalContext() {
    @autoreleasepool {
        device_ = MTLCreateSystemDefaultDevice();
        if (!device_) {
            error_ = "Failed to create system default Metal device";
            return;
        }
        queue_ = [device_ newCommandQueue];
        if (!queue_) {
            error_ = "Failed to create Metal command queue";
            return;
        }

        NSError *err = nil;
        MTLCompileOptions *opts = [[MTLCompileOptions alloc] init];
        opts.languageVersion = MTLLanguageVersion3_2;
        opts.mathMode = MTLMathModeFast;

        NSString *src = [NSString stringWithUTF8String:kMacFrameShaderSource];
        library_ = [device_ newLibraryWithSource:src options:opts error:&err];
        if (!library_) {
            error_ = err ? [[err localizedDescription] UTF8String] : "Unknown shader compile error";
            return;
        }

        auto make_pso = [&](const char *name) -> id<MTLComputePipelineState> {
            if (!error_.empty()) return nil;
            id<MTLFunction> fn = [library_ newFunctionWithName:[NSString stringWithUTF8String:name]];
            if (!fn) {
                error_ = std::string("Missing Metal kernel function: ") + name;
                return nil;
            }
            NSError *pErr = nil;
            id<MTLComputePipelineState> pso = [device_ newComputePipelineStateWithFunction:fn error:&pErr];
            if (!pso) {
                error_ = std::string("Failed to create PSO for ") + name + ": " +
                         (pErr ? [[pErr localizedDescription] UTF8String] : "unknown");
                return nil;
            }
            return pso;
        };

        pso_clear_texture_rgba16f  = make_pso("clear_texture_rgba16f");
        pso_extract_luma_y         = make_pso("extract_luma_y");
        pso_extract_luma_bgra      = make_pso("extract_luma_bgra");
        pso_pyramid_downsample     = make_pso("pyramid_downsample");
        pso_clear_pair_analysis    = make_pso("clear_pair_analysis");
        pso_analyze_pair_coarse    = make_pso("analyze_pair_coarse");
        pso_update_static_mask     = make_pso("update_static_mask");
        pso_me_hierarchical_search = make_pso("me_hierarchical_search");
        pso_flow_bilateral_smooth  = make_pso("flow_bilateral_smooth");
        pso_flow_refine_dis        = make_pso("flow_refine_dis");
        pso_compute_consistency    = make_pso("compute_consistency");
        pso_project_phase_flow     = make_pso("project_phase_flow");
        pso_synth_biplanar_yuv      = make_pso("synth_biplanar_yuv");
        pso_synth_biplanar_yuv_quad = make_pso("synth_biplanar_yuv_quad");
        pso_synth_bgra              = make_pso("synth_bgra");
        pso_blend_biplanar_yuv     = make_pso("blend_biplanar_yuv");
        pso_yuv_to_rgba16f         = make_pso("yuv_to_rgba16f");
        pso_rgba16f_to_yuv_guarded = make_pso("rgba16f_to_yuv_guarded");

        if (error_.empty()) {
            valid_ = true;
        }
    }
}

void MetalContext::dispatch2D(id<MTLComputeCommandEncoder> enc,
                              id<MTLComputePipelineState> pso,
                              uint32_t width,
                              uint32_t height) const {
    [enc setComputePipelineState:pso];
    MTLSize tg = MTLSizeMake(16, 16, 1);
    MTLSize grid = MTLSizeMake(width, height, 1);
    [enc dispatchThreads:grid threadsPerThreadgroup:tg];
}

id<MTLTexture> MetalContext::newTexture2D(MTLPixelFormat fmt,
                                          uint32_t width,
                                          uint32_t height,
                                          MTLTextureUsage usage,
                                          MTLStorageMode storage) const {
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt
                                                                                    width:width
                                                                                   height:height
                                                                                mipmapped:NO];
    desc.usage = usage;
    desc.storageMode = storage;
    return [device_ newTextureWithDescriptor:desc];
}

} // namespace macframe
