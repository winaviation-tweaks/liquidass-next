

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import "LGSymbolResolver.h"
#include <stdio.h>
#include <stdarg.h>
#include <time.h>
#include <sys/time.h>
#include <errno.h>
#include <dlfcn.h>
#include <unistd.h>

// a bit off topic but this seems to be the only path backboardd could write to other than /tmp
#define LG_LOG_PATH "/var/mobile/Library/Accessibility/liquidglass.log"

// timestamped logger
static void lglog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void lglog(const char *fmt, ...) {
    FILE *f = fopen(LG_LOG_PATH, "a");
    if (!f) return;
    struct timeval tv; gettimeofday(&tv, NULL);
    struct tm *t = localtime(&tv.tv_sec);
    char ts[32]; strftime(ts, sizeof(ts), "%H:%M:%S", t);
    fprintf(f, "[LG %s.%03d] ", ts, (int)(tv.tv_usec / 1000));
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
    fputc('\n', f);
    fclose(f);
}
#import <simd/simd.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <os/lock.h>
#include <sys/mman.h>
#include <unordered_map>
#include <fcntl.h>

static void *logResolveResult(const char *label, void *resolved) {
    if (resolved)
        lglog("resolve %s: scanner -> %p", label, resolved);
    else
        lglog("resolve %s: FAILED, build not supported by scanner (no fallback)", label);
    return resolved;
}

// must match kLGFilterType in LiquidGlassSB/Tweak.x exactly
static const char *kCustomFilterTypeName = "dylv.liquidglass.refraction";

// resolved dynamically at init, -1 until resolved (0xaa8 on 15.8.8, 0xb38 on 16.x)
static ptrdiff_t g_cmdBufOffset = -1;

// surface's primary MTLTexture, stable across 15.8.8 and 16.x
static const ptrdiff_t kSurfTexOffset = 0x58;

// how many vtable slots to copy (covers slot 0..21)
static const size_t kVtableSlots = 22;

// match msl natural 8-byte alignment for float2 to prevent struct field layout desync from padding
typedef struct {
    simd_float2 resolution;
    simd_float2 screenResolution;
    simd_float2 cardOrigin;
    simd_float2 wallpaperResolution;
    float       radius;
    float       bezelWidth;
    float       glassThickness;
    float       refractionScale;
    float       refractiveIndex;
    float       specularOpacity;
    float       specularAngle;
    simd_float2 wallpaperOrigin;
    simd_float2 samplingTransformX;
    simd_float2 samplingTransformY;
    simd_float2 samplingTransformOffset;
    float       samplingOrientation;
    float       hasShapeMask;
} LGUniforms;

typedef void (*Render13Fn)(void*,
                           void*,
                           void*,
                           void*,
                           float,
                           void*,
                           float,
                           bool,
                           void*,
                           void*,
                           float*);
typedef void     (*StopEncodersFn)(void*);
typedef uint32_t (*InternAtomFn)(const char*);
typedef void     (*AddFilterFn)(uint32_t, void*);

static StopEncodersFn  g_stopEncoders   = nullptr;
static InternAtomFn    g_internAtom     = nullptr;
static AddFilterFn     g_addFilter      = nullptr;
static Render13Fn      g_origGaussR13   = nullptr; // original render we call after our pass
static void           *g_gaussCtxValue  = nullptr; // raw gaussian vtable ptr (stripped)
static bool            g_filterRegistered = false;

static void  **g_customVtable = nullptr; // mmap'd 22-slot cloned gaussian vtable
static void   *g_customCtx    = nullptr; // mmap'd FilterSubclass-shaped block

// arm64e vtables cannot be relocated due to address diversification, making PAC devices unsupported
static const bool kIsPACSlice =
#if __has_feature(ptrauth_calls)
    true;
#else
    false;
#endif

static id<MTLComputePipelineState> g_pipeline    = nil;
static id<MTLBuffer>               g_uniformsBuf = nil;

static os_unfair_lock g_pipelineLock = OS_UNFAIR_LOCK_INIT;
static os_unfair_lock g_ppLock       = OS_UNFAIR_LOCK_INIT;
static bool           g_pipelineInit = false;

// single output texture per size, no A/B ping-pong (that caused ghosting). heap
// allocated so it survives past CXA finalization.
static std::unordered_map<uint64_t, id<MTLTexture>> *g_outTex = nullptr;

// clears ARC-managed globals before CXA finalization
__attribute__((destructor))
static void liquidGlassShutdown(void) {
    g_pipeline    = nil;
    g_uniformsBuf = nil;
}

static const char *kShaderSrc = R"MSL(
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 resolution;
    float2 screenResolution;
    float2 cardOrigin;
    float2 wallpaperResolution;
    float  radius;
    float  bezelWidth;
    float  glassThickness;
    float  refractionScale;
    float  refractiveIndex;
    float  specularOpacity;
    float  specularAngle;
    float2 wallpaperOrigin;
    float2 samplingTransformX;
    float2 samplingTransformY;
    float2 samplingTransformOffset;
    float  samplingOrientation;
    float  hasShapeMask;
};

float surfaceConvexSquircle(float x) {
    return pow(1.0 - pow(1.0 - x, 4.0), 0.25);
}

float2 refractRay(float2 normal, float eta) {
    float cosI = -normal.y;
    float k    = 1.0 - eta * eta * (1.0 - cosI * cosI);
    if (k < 0.0) return float2(0.0);
    float sq = sqrt(k);
    return float2(-(eta * cosI + sq) * normal.x,
                    eta - (eta * cosI + sq) * normal.y);
}

float rawRefraction(float br, float gt, float bw, float eta) {
    float x  = clamp(br, 0.05, 0.95);
    float y  = surfaceConvexSquircle(x);
    float y2 = surfaceConvexSquircle(x + 0.001);
    float d  = (y2 - y) / 0.001;
    float m  = sqrt(d * d + 1.0);
    float2 n = float2(-d / m, -1.0 / m);
    float2 r = refractRay(n, eta);
    if (length(r) < 0.0001 || abs(r.y) < 0.0001) return 0.0;
    return r.x * (y * bw + gt) / r.y;
}

float displacementAtRatio(float br, float gt, float bw, float eta) {
    float peak = rawRefraction(0.05, gt, bw, eta);
    if (abs(peak) < 0.0001) return 0.0;
    float raw = rawRefraction(br, gt, bw, eta);
    return (raw / peak) * (1.0 - smoothstep(0.0, 1.0, br));
}

float linearize(float c) {
    return c > 0.04045 ? pow((c + 0.055) / 1.055, 2.4) : c / 12.92;
}
float gammaEncode(float c) {
    return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1.0 / 2.4) - 0.055;
}

float3 srgbToXyz(float3 rgb) {
    float3 l = float3(linearize(rgb.r), linearize(rgb.g), linearize(rgb.b));
    return float3(dot(l, float3(0.4124, 0.3576, 0.1805)),
                  dot(l, float3(0.2126, 0.7152, 0.0722)),
                  dot(l, float3(0.0193, 0.1192, 0.9505)));
}
float3 xyzToSrgb(float3 xyz) {
    float3 l = float3(dot(xyz, float3( 3.2406,-1.5372,-0.4986)),
                      dot(xyz, float3(-0.9689, 1.8758, 0.0415)),
                      dot(xyz, float3( 0.0557,-0.2040, 1.0570)));
    return clamp(float3(gammaEncode(l.r), gammaEncode(l.g), gammaEncode(l.b)), 0.0, 1.0);
}

float labF(float t)    { float t3 = t*t*t; return t3>0.008856? pow(t,1.0/3.0) : 7.787*t+16.0/116.0; }
float labInvF(float t) { float t3 = t*t*t; return t3>0.008856? t3 : (t-16.0/116.0)/7.787; }

float3 xyzToLab(float3 xyz) {
    float3 n = xyz / float3(0.95047, 1.0, 1.08883);
    float fx = labF(n.x), fy = labF(n.y), fz = labF(n.z);
    return float3(116.0*fy - 16.0, 500.0*(fx-fy), 200.0*(fy-fz));
}
float3 labToXyz(float3 lab) {
    float fy = (lab.x+16.0)/116.0, fx = fy+lab.y/500.0, fz = fy-lab.z/200.0;
    return float3(0.95047*labInvF(fx), labInvF(fy), 1.08883*labInvF(fz));
}
float3 srgbToLch(float3 rgb) {
    float3 lab = xyzToLab(srgbToXyz(rgb));
    return float3(lab.x, length(lab.yz), atan2(lab.z, lab.y));
}
float3 lchToSrgb(float3 lch) {
    float3 lab = float3(lch.x, cos(lch.z)*lch.y, sin(lch.z)*lch.y);
    return xyzToSrgb(labToXyz(lab));
}

kernel void liquidGlass(
    texture2d<float, access::sample> src [[texture(0)]],
    texture2d<float, access::write>  dst [[texture(1)]],
    constant Uniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    const uint W = dst.get_width(), H = dst.get_height();
    if (gid.x >= W || gid.y >= H) return;

    constexpr sampler s(filter::linear, address::clamp_to_edge);

    float2 localUV  = (float2(gid) + 0.5) / float2(W, H);
    float2 px       = localUV * u.resolution;
    float  fw       = u.resolution.x, fh = u.resolution.y;
    float  R        = u.radius, bezel = u.bezelWidth;
    float  eta      = 1.0 / u.refractiveIndex;
    float  shortest = min(fw, fh);

    bool nearlySquare        = abs(fw - fh) < max(4.0, shortest * 0.035);
    bool useCircularGeometry = nearlySquare && R >= shortest * 0.34;

    bool inLeft = px.x < R, inRight = px.x > fw - R;
    bool inTop  = px.y < R, inBot   = px.y > fh - R;
    bool inCorner = (inLeft || inRight) && (inTop || inBot);

    float cx = inLeft ? px.x - R : inRight ? px.x - (fw - R) : 0.0;
    float cy = inTop  ? px.y - R : inBot   ? px.y - (fh - R) : 0.0;
    float distFromCenter = length(float2(cx, cy));

    if (!useCircularGeometry && inCorner && distFromCenter > R + 1.0) {
        dst.write(src.sample(s, localUV), gid);
        return;
    }

    float distFromSide; float2 dir;

    if (useCircularGeometry) {
        float  cR = shortest * 0.5;
        float2 cC = float2(fw * 0.5, fh * 0.5);
        float2 fc = px - cC;
        float  cd = length(fc);
        if (cd > cR + 1.0) { dst.write(src.sample(s, localUV), gid); return; }
        distFromSide   = max(0.0, cR - cd);
        dir            = cd > 0.001 ? normalize(fc) : float2(0, -1);
        distFromCenter = cd;
    } else if (inCorner) {
        distFromSide = max(0.0, R - distFromCenter);
        dir          = distFromCenter > 0.001 ? normalize(float2(cx, cy)) : float2(0);
    } else {
        float dL = px.x, dR = fw - px.x, dT = px.y, dB = fh - px.y;
        float dm = min(min(dL, dR), min(dT, dB));
        distFromSide = dm;
        dir = float2((dL < dR && dL == dm) ? -1.0 : (dR <= dL && dR == dm) ?  1.0 : 0.0,
                     (dT < dB && dT == dm) ? -1.0 : (dB <= dT && dB == dm) ?  1.0 : 0.0);
    }

    float edgeOpacity = (useCircularGeometry || inCorner) ?
        clamp(1.0 - max(0.0, distFromCenter -
              (useCircularGeometry ? shortest * 0.5 : R)), 0.0, 1.0) : 1.0;

    // flat interior pixels reduce to a raw passthrough sample
    if (!useCircularGeometry && !inCorner && distFromSide >= bezel) {
        dst.write(src.sample(s, localUV), gid);
        return;
    }

    float bezelRatio = clamp(distFromSide / bezel, 0.0, 1.0);
    float normDisp   = (distFromSide < bezel) ?
        displacementAtRatio(bezelRatio, u.glassThickness, bezel, eta) : 0.0;
    float2 dispPx    = -dir * normDisp * bezel * u.refractionScale * edgeOpacity;

    float2 screenPx = u.cardOrigin + px + dispPx;
    float2 mapped   = u.samplingTransformOffset
                    + screenPx.x * u.samplingTransformX
                    + screenPx.y * u.samplingTransformY;
    float2 imgPx    = mapped - u.wallpaperOrigin;
    float2 sampleUV = imgPx / u.wallpaperResolution;

    int ori = int(round(u.samplingOrientation));
    if      (ori == 2) sampleUV = float2(1.0 - sampleUV.x, 1.0 - sampleUV.y);
    else if (ori == 3) sampleUV = float2(1.0 - sampleUV.y,       sampleUV.x);
    else if (ori == 4) sampleUV = float2(      sampleUV.y,  1.0 - sampleUV.x);
    sampleUV = clamp(sampleUV, 0.0, 1.0);

    float4 bg = src.sample(s, sampleUV);

    float2 lightDir    = float2(cos(u.specularAngle), -sin(u.specularAngle));
    float2 specDir     = dir;
    if (!useCircularGeometry) {
        float2 cv = (px - float2(fw * 0.5, fh * 0.5)) / max(float2(fw, fh), float2(1.0));
        specDir = length(cv) > 0.001 ? normalize(cv) : dir;
    }

    float specDot  = dot(specDir, lightDir);
    float strokePx = useCircularGeometry
        ? max(2.25, shortest * 0.040)
        : clamp(shortest * 0.018, 2.0, 5.5);

    float strokeMask  = clamp(1.0 - (distFromSide / strokePx), 0.0, 1.0);
    float lobeStart   = 0.66, lobeWidth = 0.20;
    float cornerSpec  = smoothstep(0.46, 0.90, abs(specDot));
    float specLobe    = useCircularGeometry ? cornerSpec
        : max(smoothstep(lobeStart, lobeStart + lobeWidth,  specDot),
              smoothstep(lobeStart, lobeStart + lobeWidth, -specDot));
    float fresnel     = pow(clamp(1.0 - bezelRatio, 0.0, 1.0), 2.2) * edgeOpacity;
    float specular    = specLobe * strokeMask * u.specularOpacity * 2.15 * edgeOpacity;
    float highlight   = specular + fresnel * 0.34;

    float3 lch = srgbToLch(clamp(bg.rgb, 0.0, 1.0));
    lch.x = clamp(lch.x + highlight * 36.0, 0.0, 100.0);
    lch.y = max(0.0, lch.y - highlight * 9.0);
    bg.rgb = mix(bg.rgb, lchToSrgb(lch), clamp(highlight * 0.70, 0.0, 1.0));

    dst.write(float4(bg.rgb, edgeOpacity), gid);
}
)MSL";

static void ensurePipeline(__unsafe_unretained id<MTLDevice> device) {
    os_unfair_lock_lock(&g_pipelineLock);
    if (!g_pipelineInit) {
        g_pipelineInit = true; // set first so a compile failure doesnt spin

        NSError *err = nil;
        NSString *src = [NSString stringWithUTF8String:kShaderSrc];
        id<MTLLibrary> lib = [device newLibraryWithSource:src options:nil error:&err];
        if (!lib) {
            lglog("Metal compile failed: %s", err.localizedDescription.UTF8String);
            os_unfair_lock_unlock(&g_pipelineLock);
            return;
        }
        id<MTLFunction> fn = [lib newFunctionWithName:@"liquidGlass"];
        g_pipeline = [device newComputePipelineStateWithFunction:fn error:&err];
        if (!g_pipeline)
            lglog("Pipeline state failed: %s", err.localizedDescription.UTF8String);
        else
            lglog("pipeline ready");
    }
    os_unfair_lock_unlock(&g_pipelineLock);
}

// corner radius/bezel as a ratio of the shortest surface side, recomputed per frame
static const float kCornerRadiusRatio = 28.0f / 220.0f;
static const float kBezelWidthRatio   = kCornerRadiusRatio * 1.4f;

static void ensureUniforms(__unsafe_unretained id<MTLDevice> device, uint64_t w, uint64_t h) {
    if (g_uniformsBuf) return; // buffer itself only needs allocating once

    g_uniformsBuf = [device newBufferWithLength:sizeof(LGUniforms)
                                        options:MTLResourceStorageModeShared];
    if (!g_uniformsBuf) return;

    LGUniforms *u = (LGUniforms *)g_uniformsBuf.contents;

    // screenResolution is a placeholder since private apis returned garbage data, we will binja the struct if it ever becomes necessary
    /*
    typedef void *IOMobileFramebufferRef;
    typedef struct { float width; float height; } IOMobileFramebufferDisplaySize;
    typedef kern_return_t (*IOMFBGetMainDisplayFn)(IOMobileFramebufferRef *);
    typedef kern_return_t (*IOMFBGetDisplaySizeFn)(IOMobileFramebufferRef, IOMobileFramebufferDisplaySize *);

    void *iomfb = dlopen("/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer",
                        RTLD_LAZY);
    if (!iomfb) lglog("screen resolution: dlopen(IOMobileFramebuffer) failed: %s", dlerror());

    IOMFBGetMainDisplayFn getMainDisplay = iomfb ?
        (IOMFBGetMainDisplayFn)dlsym(iomfb, "IOMobileFramebufferGetMainDisplay") : nullptr;
    IOMFBGetDisplaySizeFn getDisplaySize = iomfb ?
        (IOMFBGetDisplaySizeFn)dlsym(iomfb, "IOMobileFramebufferGetDisplaySize") : nullptr;
    if (iomfb && (!getMainDisplay || !getDisplaySize))
        lglog("screen resolution: dlsym off IOMobileFramebuffer handle failed (getMainDisplay=%p getDisplaySize=%p)",
              (void *)getMainDisplay, (void *)getDisplaySize);

    bool gotScreen = false;
    if (getMainDisplay && getDisplaySize) {
        IOMobileFramebufferRef fb = NULL;
        kern_return_t kr1 = getMainDisplay(&fb);
        if (kr1 == KERN_SUCCESS && fb) {
            IOMobileFramebufferDisplaySize sz = {0.f, 0.f};
            kern_return_t kr2 = getDisplaySize(fb, &sz);
            if (kr2 == KERN_SUCCESS && sz.width > 0.f && sz.height > 0.f) {
                u->screenResolution = simd_make_float2(sz.width, sz.height);
                lglog("screen resolution: %.0fx%.0f px (IOMobileFramebuffer)", sz.width, sz.height);
                gotScreen = true;
            } else {
                lglog("screen resolution: GetDisplaySize kr=%#x size=%.0fx%.0f", kr2, sz.width, sz.height);
            }
        } else {
            lglog("screen resolution: GetMainDisplay kr=%#x fb=%p", kr1, fb);
        }
    }
    if (!gotScreen) {
        u->screenResolution = simd_make_float2(750.f, 1334.f);
        lglog("screen resolution: IOMobileFramebuffer unavailable, using default");
    }
    */
    u->screenResolution = simd_make_float2(750.f, 1334.f);
    u->cardOrigin               = simd_make_float2(0.f, 0.f);
    u->glassThickness          = 5.f;
    u->refractionScale         = 0.5f;
    u->refractiveIndex         = 1.5f;
    u->specularOpacity         = 0.7f;
    u->specularAngle           = 0.785398f; // pi/4
    u->wallpaperOrigin         = simd_make_float2(0.f, 0.f);
    u->samplingTransformX      = simd_make_float2(1.f, 0.f);
    u->samplingTransformY      = simd_make_float2(0.f, 1.f);
    u->samplingTransformOffset = simd_make_float2(0.f, 0.f);
    u->samplingOrientation     = 1.f;
    u->hasShapeMask            = 0.f;

    lglog("uniforms buffer allocated (geometry refreshed per-frame)");
}

static void updateUniformsForFrame(uint64_t w, uint64_t h) {
    if (!g_uniformsBuf) return;
    LGUniforms *u = (LGUniforms *)g_uniformsBuf.contents;

    float fw = (float)w, fh = (float)h;
    float shortest = fminf(fw, fh);

    u->resolution          = simd_make_float2(fw, fh);
    u->wallpaperResolution = simd_make_float2(fw, fh);
    u->radius              = kCornerRadiusRatio * shortest;
    u->bezelWidth           = kBezelWidthRatio   * shortest;
}

static id<MTLTexture> allocTex(__unsafe_unretained id<MTLDevice> device,
                                NSUInteger w, NSUInteger h,
                                MTLPixelFormat fmt)
{
    MTLTextureDescriptor *desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt
                                                          width:w
                                                         height:h
                                                      mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    return [device newTextureWithDescriptor:desc];
}

static void ourCustomRender13(void *self, void *filter, void *layer, void *ctx,
                               float opacity, void *surface, float scale,
                               bool flag, void *cm, void *shape, float *out)
{
    static uint64_t tsum_stop = 0, tsum_ours = 0, tsum_gauss = 0, tcount = 0;
    uint64_t t_start = mach_absolute_time();

    // early-call log to pinpoint hanging step if the render server freezes without crashing
    static uint64_t g_traceCalls = 0;
    uint64_t callN = ++g_traceCalls;
#define R13TRACE(...) do { if (callN <= 3) lglog(__VA_ARGS__); } while (0)
    R13TRACE("R13[%llu] ENTER ctx=%p surface=%p opacity=%.2f scale=%.2f flag=%d",
             callN, ctx, surface, opacity, scale, (int)flag);

    auto *metalCtx = (uint8_t *)ctx;
    auto *surf     = (uint8_t *)surface;

    if (g_cmdBufOffset < 0) {
        lglog("ourCustomRender13: command-buffer offset unresolved, skipping");
        return;
    }

    void *rawCmdBuf  = *(void **)(metalCtx + g_cmdBufOffset);
    void *rawOrigTex = *(void **)(surf     + kSurfTexOffset);

    if (!rawCmdBuf || !rawOrigTex) {
        lglog("ourCustomRender13: early exit, cmdBuf=%p origTex=%p", rawCmdBuf, rawOrigTex);
        return;
    }

    __unsafe_unretained id<MTLCommandBuffer> cmdBuf  = (__bridge id<MTLCommandBuffer>)rawCmdBuf;
    __unsafe_unretained id<MTLTexture>       origTex = (__bridge id<MTLTexture>)rawOrigTex;

    __unsafe_unretained id<MTLDevice> device = origTex.device;
    if (!device) { lglog("ourCustomRender13: origTex has no device, skip"); return; }

    uint64_t w = (uint64_t)origTex.width;
    uint64_t h = (uint64_t)origTex.height;
    if (w == 0 || h == 0) { lglog("ourCustomRender13: zero dims, skip"); return; }
    R13TRACE("R13[%llu] cmdBuf=%p origTex=%p device=%p dims=%llux%llu", callN, rawCmdBuf, rawOrigTex, (__bridge void *)device, w, h);

    ensurePipeline(device);
    if (!g_pipeline) { lglog("ourCustomRender13: no pipeline"); return; }

    ensureUniforms(device, w, h);
    if (!g_uniformsBuf) { lglog("ourCustomRender13: no uniforms buf"); return; }
    updateUniformsForFrame(w, h);
    R13TRACE("R13[%llu] pipeline+uniforms ready", callN);

    uint64_t key = ((uint64_t)w << 32) | (uint64_t)h;
    id<MTLTexture> texOut = nil;

    os_unfair_lock_lock(&g_ppLock);
    auto it = g_outTex->find(key);
    if (it == g_outTex->end()) {
        MTLPixelFormat fmt = origTex.pixelFormat;
        lglog("ourCustomRender13: allocating output texture %llux%llu fmt=%lu",
              w, h, (unsigned long)fmt);
        id<MTLTexture> t = allocTex(device, (NSUInteger)w, (NSUInteger)h, fmt);
        if (!t) {
            lglog("ourCustomRender13: output texture alloc failed");
            os_unfair_lock_unlock(&g_ppLock);
            return;
        }
        (*g_outTex)[key] = t;
        it = g_outTex->find(key);
    }
    texOut = it->second;
    os_unfair_lock_unlock(&g_ppLock);

    if (!texOut) { lglog("ourCustomRender13: nil texOut"); return; }

    void *savedOrigTex = rawOrigTex;

    if (!g_stopEncoders) { lglog("ourCustomRender13: null stopEncoders"); return; }
    R13TRACE("R13[%llu] before stopEncoders(%p)", callN, (void *)g_stopEncoders);
    g_stopEncoders(ctx);
    uint64_t t_afterStop = mach_absolute_time();
    R13TRACE("R13[%llu] after stopEncoders, before encoder", callN);

    id<MTLComputeCommandEncoder> enc = [cmdBuf computeCommandEncoder];
    if (!enc) { lglog("ourCustomRender13: nil encoder"); return; }
    [enc setComputePipelineState:g_pipeline];
    [enc setTexture:origTex atIndex:0];
    [enc setTexture:texOut  atIndex:1];
    [enc setBuffer:g_uniformsBuf offset:0 atIndex:0];
    MTLSize grid = { (w+7)/8, (h+7)/8, 1 }, tg = { 8, 8, 1 };
    [enc dispatchThreadgroups:grid threadsPerThreadgroup:tg];
    [enc endEncoding];
    uint64_t t_afterOurs = mach_absolute_time();
    R13TRACE("R13[%llu] after our compute dispatch", callN);

    // redirect surface source to texOut, let real gaussian render composite with zero scale, then restore
    *(void **)(surf + kSurfTexOffset) = (__bridge void *)texOut;

    R13TRACE("R13[%llu] before g_origGaussR13(%p)", callN, (void *)g_origGaussR13);
    if (g_origGaussR13) {
        g_origGaussR13(self, filter, layer, ctx, opacity, surface,
                       0.0f, flag, cm, shape, out);
    }
    uint64_t t_afterGauss = mach_absolute_time();
    R13TRACE("R13[%llu] after g_origGaussR13", callN);

    *(void **)(surf + kSurfTexOffset) = savedOrigTex;
    R13TRACE("R13[%llu] DONE", callN);

    // cpuside timing, logged every 60 calls
    tsum_stop  += (t_afterStop  - t_start);
    tsum_ours  += (t_afterOurs  - t_afterStop);
    tsum_gauss += (t_afterGauss - t_afterOurs);
    tcount++;
    if (tcount >= 60) {
        static mach_timebase_info_data_t tb = {0, 0};
        if (tb.denom == 0) mach_timebase_info(&tb);
        double scaleUs = (double)tb.numer / tb.denom / 1000.0;
        double avgStop  = (double)tsum_stop  / tcount * scaleUs;
        double avgOurs  = (double)tsum_ours  / tcount * scaleUs;
        double avgGauss = (double)tsum_gauss / tcount * scaleUs;
        double avgTotal = avgStop + avgOurs + avgGauss;
        lglog("timing (avg over %llu calls): stopEncoders=%.0fus  ourCompute=%.0fus  gaussCall=%.0fus  total=%.0fus (%.2fms)",
              tcount, avgStop, avgOurs, avgGauss, avgTotal, avgTotal);
        tsum_stop = tsum_ours = tsum_gauss = 0;
        tcount = 0;
    }
#undef R13TRACE
}

// returns not identity for the non-pac clone path while the pac path keeps the real identity
static int ourIdentityStub(void *self, void *filter) {
    static bool identityLogged = false;
    if (!identityLogged) {
        identityLogged = true;
        lglog("ourIdentityStub: first call, CA is dispatching into our vtable (self=%p filter=%p)", self, filter);
    }
    return 0;
}

// must wait for filter_table to exist before adding, or system blur breaks
static bool registerCustomFilter(void) {
    void **filterTableSlot = (void **)LGResolve_FilterTableSlot();
    if (!filterTableSlot) {
        lglog("registerCustomFilter: could not resolve filter_table, aborting (no fallback)");
        return false;
    }
    if (!*filterTableSlot) {
        lglog("registerCustomFilter: filter_table null, retrying in 250ms");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
                       ^{ registerCustomFilter(); });
        return false;
    }

    if (g_filterRegistered) return true; // idempotent

    void **gaussCtxSlot = (void **)LGResolve_GaussianCtxSlot();
    if (!gaussCtxSlot) {
        lglog("registerCustomFilter: could not resolve gaussian context, aborting (no fallback)");
        return false;
    }
    // strip PAC signature from descriptor vtable pointer to get raw address before dereferencing
    g_gaussCtxValue = LGSymStripCode((void *)*gaussCtxSlot);
    lglog("registerCustomFilter: g_gaussCtxValue = %p (raw from %p)", g_gaussCtxValue, *gaussCtxSlot);
    void **gaussVtable = (void **)g_gaussCtxValue;
    if (!gaussVtable) {
        lglog("registerCustomFilter: gaussian vtable not found");
        return false;
    }
    lglog("registerCustomFilter: gaussian vtable @ %p", gaussVtable);

    // render slot shifts across versions (12 on 15.8.8/16.2, 13 on 16.7)
    int renderSlot = LGResolve_RenderVtableSlot((void * const *)gaussVtable, (int)kVtableSlots);
    if (renderSlot < 0 || renderSlot >= (int)kVtableSlots) {
        lglog("registerCustomFilter: could not resolve render vtable slot (got %d), aborting", renderSlot);
        return false;
    }
    lglog("registerCustomFilter: render vtable slot = %d", renderSlot);

    if (!g_internAtom || !g_addFilter) {
        lglog("registerCustomFilter: internAtom=%p addFilter=%p, aborting",
              (void *)g_internAtom, (void *)g_addFilter);
        return false;
    }
    uint32_t atomId    = g_internAtom(kCustomFilterTypeName);
    uint32_t gaussAtom = g_internAtom("gaussianBlur");
    lglog("registerCustomFilter: atom('%s')=0x%x  gaussian=0x%x  collision=%s",
          kCustomFilterTypeName, atomId, gaussAtom,
          atomId == gaussAtom ? "YES-BAD" : "no");

    // clone gaussian vtable to override identity and render slots, arm64e is noop as vtables cannot be relocated
    g_origGaussR13 = (Render13Fn)LGSymMakeCallable(gaussVtable[renderSlot]);
    lglog("registerCustomFilter: g_origGaussR13 = %p", (void *)g_origGaussR13);

    g_customVtable = (void **)mmap(NULL, kVtableSlots * sizeof(void *),
                                    PROT_READ | PROT_WRITE,
                                    MAP_ANON | MAP_PRIVATE, -1, 0);
    if (g_customVtable == MAP_FAILED) {
        lglog("registerCustomFilter: vtable mmap failed errno=%d", errno);
        g_customVtable = nullptr;
        return false;
    }
    memcpy(g_customVtable, gaussVtable, kVtableSlots * sizeof(void *));
    g_customVtable[0]          = LGSymStripCode((void *)&ourIdentityStub);
    g_customVtable[renderSlot] = LGSymStripCode((void *)&ourCustomRender13);

    g_customCtx = mmap(NULL, 256, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (g_customCtx == MAP_FAILED) {
        lglog("registerCustomFilter: ctx mmap failed errno=%d", errno);
        munmap(g_customVtable, kVtableSlots * sizeof(void *));
        g_customVtable = nullptr;
        g_customCtx    = nullptr;
        return false;
    }
    *(void **)g_customCtx = g_customVtable;

    g_addFilter(atomId, g_customCtx);
    g_filterRegistered = true;
    lglog("registerCustomFilter: done ctx=%p renderSlot=%d atom=0x%x", g_customCtx, renderSlot, atomId);
    return true;
}

__attribute__((constructor))
static void tweakInit(void) {
    { FILE *lf = fopen(LG_LOG_PATH, "w"); if (lf) fclose(lf); }

    NSOperatingSystemVersion osv = NSProcessInfo.processInfo.operatingSystemVersion;
    lglog("===== LiquidGlass (backboardd) on iOS %ld.%ld.%ld =====",
          (long)osv.majorVersion, (long)osv.minorVersion, (long)osv.patchVersion);

    // arm64e is unsupported because address-diversified pac signatures prevent vtable relocation and cause crashes
    if (kIsPACSlice) {
        lglog("init: unsupported (PAC available)");
        return;
    }

    if (!LGSymResolverInit()) {
        lglog("init: LGSymResolverInit failed, QuartzCore not loaded yet?");
        return;
    }

    void *stopEnc = logResolveResult("stop_encoders", LGResolve_StopEncoders());
    void *internA = logResolveResult("CAInternAtomWithCString", LGResolve_CAInternAtomWithCString());
    void *addF    = logResolveResult("add_filter", LGResolve_AddFilter());

    // PAC-sign the scanned addresses so our authenticated calls succeed on arm64e
    g_stopEncoders = (StopEncodersFn)LGSymMakeCallable(stopEnc);
    g_internAtom   = (InternAtomFn)LGSymMakeCallable(internA);
    g_addFilter    = (AddFilterFn)LGSymMakeCallable(addF);

    lglog("init: stopEncoders=%p internAtom=%p addFilter=%p", stopEnc, internA, addF);

    if (!stopEnc || !internA || !addF) {
        lglog("init: required symbol(s) unresolved on this build, not activating (no fallback)");
        return;
    }

    g_cmdBufOffset = LGResolve_MetalCmdBufOffset();
    if (g_cmdBufOffset < 0)
        lglog("init: command-buffer offset unresolved, filter registers but compute pass is skipped");
    else
        lglog("init: MetalContext command-buffer offset = %#lx", (long)g_cmdBufOffset);

    g_outTex = new std::unordered_map<uint64_t, id<MTLTexture>>();

    registerCustomFilter();

    lglog("ready");
}
