

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import "LGSymbolResolver.h"
#include <stdio.h>
#include <stdarg.h>
#include <time.h>
#include <sys/time.h>
#include <errno.h>

// timestamped logger to /tmp/liquidglass.log
static void lglog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void lglog(const char *fmt, ...) {
    FILE *f = fopen("/tmp/liquidglass.log", "a");
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


// fallback addresses for iOS 16.7.11
static const uintptr_t kFB_FilterTable   = 0x1e1deee30;
static const uintptr_t kFB_GaussianCtx   = 0x1dcdf1710;
static const uintptr_t kFB_StopEncoders  = 0x188340284;
static const uintptr_t kFB_InternAtom    = 0x1883405a0;
static const uintptr_t kFB_AddFilter     = 0x188392e18;

static intptr_t getSlide(void) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "QuartzCore"))
            return _dyld_get_image_vmaddr_slide(i);
    }
    return 0;
}

static void *resolveWithFallback(const char *label, void *resolved, uintptr_t fallbackUnslid) {
    if (resolved) {
        lglog("resolve %s: scanner -> %p", label, resolved);
        return resolved;
    }
    intptr_t slide = getSlide();
    void *fb = (void *)(fallbackUnslid + slide);
    lglog("resolve %s: scanner returned null, using FALLBACK %p (slide=%tx)", label, fb, slide);
    return fb;
}

// must match string in LiquidGlassSB/Tweak.x
static const char *kCustomFilterTypeName  = "dylv.liquidglass.refraction";

static const ptrdiff_t kMtlDeviceOffset  = 0xb20;
static const ptrdiff_t kMtlCmdBufOffset  = 0xb38;

static const ptrdiff_t kSurfTexOffset    = 0x58;
static const ptrdiff_t kSurfWidthOffset  = 0x70;
static const ptrdiff_t kSurfHeightOffset = 0x78;

static const size_t kVtableSlots = 22;

typedef struct __attribute__((packed)) {
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
    float       blur;
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
static Render13Fn      g_origGaussR13   = nullptr; // original slot13 we call after our pass
static void           *g_gaussCtxValue  = nullptr;
static bool            g_filterRegistered = false;


static void  **g_customVtable = nullptr; // mmap'd 22-slot vtable
static void   *g_customCtx    = nullptr; // mmap'd CAML::Context-shaped block

static id<MTLComputePipelineState> g_pipeline    = nil;
static id<MTLBuffer>               g_uniformsBuf = nil;

static os_unfair_lock g_pipelineLock = OS_UNFAIR_LOCK_INIT;
static os_unfair_lock g_ppLock       = OS_UNFAIR_LOCK_INIT;
static bool           g_pipelineInit = false;

static std::unordered_map<uint64_t, id<MTLTexture>> *g_outTex = nullptr;

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
    float  blur;
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
    float2 prismOff    = dispPx / max(u.wallpaperResolution, float2(1.0));
    float  dispersion  = clamp(length(prismOff) * 24.0, 0.0, 0.012);
    float2 redUV       = clamp(sampleUV - prismOff * 0.55, 0.0, 1.0);
    float2 blueUV      = clamp(sampleUV + prismOff * 0.55, 0.0, 1.0);
    float3 dispersed   = float3(src.sample(s, mix(sampleUV, redUV,  dispersion * 6.0)).r,
                                bg.g,
                                src.sample(s, mix(sampleUV, blueUV, dispersion * 6.0)).b);
    bg.rgb = mix(bg.rgb, dispersed, dispersion * 0.4);

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

static const float kCornerRadiusRatio = 28.0f / 220.0f;
static const float kBezelWidthRatio   = 36.0f / 220.0f;

static void ensureUniforms(__unsafe_unretained id<MTLDevice> device, uint64_t w, uint64_t h) {
    if (g_uniformsBuf) return; // buffer itself only needs allocating once

    g_uniformsBuf = [device newBufferWithLength:sizeof(LGUniforms)
                                        options:MTLResourceStorageModeShared];
    if (!g_uniformsBuf) return;

    LGUniforms *u = (LGUniforms *)g_uniformsBuf.contents;

    u->screenResolution        = simd_make_float2(750.f, 1334.f); // TODO: read real screen size
    u->cardOrigin               = simd_make_float2(0.f, 0.f);
    u->glassThickness          = 5.f;
    u->refractionScale         = 0.5f;
    u->refractiveIndex         = 1.5f;
    u->specularOpacity         = 0.7f;
    u->specularAngle           = 0.785398f; // pi/4
    u->blur                    = 8.f;       // informational, actual blur is the chained gaussianBlur
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
    static uint64_t callCount = 0;
    ++callCount;

    if (callCount == 1) {
        lglog("ourCustomRender13 first call FULL ARGS:");
        lglog("  self=%p filter=%p layer=%p ctx=%p", self, filter, layer, ctx);
        lglog("  opacity=%.3f surface=%p scale=%.3f flag=%d", opacity, surface, scale, (int)flag);
        lglog("  cm=%p shape=%p out=%p", cm, shape, out);
        lglog("  g_customCtx=%p", g_customCtx);
        lglog("  ctx==g_customCtx: %s", ctx == g_customCtx ? "YES, x3 is CAML::Context" : "no, x3 is MetalContext");
        for (void *candidate : {self, filter, layer, ctx}) {
            @try {
                void *maybeDevice = *(void **)((uint8_t *)candidate + 0xb20);
                lglog("  candidate %p + 0xb20 = %p %s",
                      candidate, maybeDevice,
                      maybeDevice ? "(non-null, likely MetalCtx)" : "(null)");
            } @catch (...) {}
        }
    } else if (callCount % 60 == 1) {
        lglog("ourCustomRender13 #%llu opacity=%.3f surface=%p ctx=%p match=%s",
              callCount, opacity, surface, ctx,
              ctx == g_customCtx ? "ctx=ours" : "ctx=MetalCtx");
    }

    auto *metalCtx = (uint8_t *)ctx;
    auto *surf     = (uint8_t *)surface;

    void *rawDevice  = *(void **)(metalCtx + kMtlDeviceOffset);
    void *rawCmdBuf  = *(void **)(metalCtx + kMtlCmdBufOffset);
    void *rawOrigTex = *(void **)(surf      + kSurfTexOffset);

    if (!rawDevice || !rawCmdBuf || !rawOrigTex) {
        lglog("ourCustomRender13: early exit, device=%p cmdBuf=%p origTex=%p",
              rawDevice, rawCmdBuf, rawOrigTex);
        return;
    }

    __unsafe_unretained id<MTLDevice>        device  = (__bridge id<MTLDevice>)rawDevice;
    __unsafe_unretained id<MTLCommandBuffer> cmdBuf  = (__bridge id<MTLCommandBuffer>)rawCmdBuf;
    __unsafe_unretained id<MTLTexture>       origTex = (__bridge id<MTLTexture>)rawOrigTex;

    uint64_t w = *(uint64_t *)(surf + kSurfWidthOffset);
    uint64_t h = *(uint64_t *)(surf + kSurfHeightOffset);
    if (w == 0 || h == 0) { lglog("ourCustomRender13: zero dims, skip"); return; }

    ensurePipeline(device);
    if (!g_pipeline) { lglog("ourCustomRender13: no pipeline"); return; }

    ensureUniforms(device, w, h);
    if (!g_uniformsBuf) { lglog("ourCustomRender13: no uniforms buf"); return; }
    updateUniformsForFrame(w, h);

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

    static uint64_t tsum_stop=0, tsum_compute=0, tsum_gauss=0, tcount=0;
    uint64_t t0 = mach_absolute_time();

    if (!g_stopEncoders) { lglog("ourCustomRender13: g_stopEncoders null, skip"); return; }
    g_stopEncoders(ctx);

    uint64_t t1 = mach_absolute_time();

    id<MTLComputeCommandEncoder> enc = [cmdBuf computeCommandEncoder];
    if (!enc) { lglog("ourCustomRender13: nil compute encoder"); return; }

    [enc setComputePipelineState:g_pipeline];
    [enc setTexture:origTex atIndex:0];
    [enc setTexture:texOut  atIndex:1];
    [enc setBuffer:g_uniformsBuf offset:0 atIndex:0];

    MTLSize gridSize        = { (w + 7) / 8, (h + 7) / 8, 1 };
    MTLSize threadgroupSize = { 8, 8, 1 };
    [enc dispatchThreadgroups:gridSize threadsPerThreadgroup:threadgroupSize];
    [enc endEncoding];

    uint64_t t3 = mach_absolute_time();

    *(void **)(surf + kSurfTexOffset) = (__bridge void *)texOut;

    if (g_origGaussR13) {
        void *gaussSelf = g_gaussCtxValue ? g_gaussCtxValue : self;
        g_origGaussR13(gaussSelf, filter, layer, ctx, opacity, surface,
                       0.0f, flag, cm, shape, out);
    }

    *(void **)(surf + kSurfTexOffset) = savedOrigTex;

    uint64_t t4 = mach_absolute_time();

    tsum_stop    += (t1 - t0);
    tsum_compute += (t3 - t1);   // stop_encoders->enc create + dispatch + end
    tsum_gauss   += (t4 - t3);   // g_origGaussR13 call
    tcount++;
    if (tcount % 60 == 0) {
        mach_timebase_info_data_t tb; mach_timebase_info(&tb);
        double scale_us = (double)tb.numer / tb.denom / 1000.0;
        double avg_stop    = (double)tsum_stop    / 60 * scale_us;
        double avg_compute = (double)tsum_compute / 60 * scale_us;
        double avg_gauss   = (double)tsum_gauss   / 60 * scale_us;
        lglog("timing: stop=%.0fus compute=%.0fus gauss=%.0fus  total=%.0fus (%.1fms)",
              avg_stop, avg_compute, avg_gauss,
              avg_stop + avg_compute + avg_gauss,
              (avg_stop + avg_compute + avg_gauss) / 1000.0);
        tsum_stop = tsum_compute = tsum_gauss = 0;
    }
}

static int ourIdentityStub(void *self, void *filter) {
    return 0;
}

// must wait for filter_table to exist before adding, or system blur breaks
static bool registerCustomFilter(void) {
    void **filterTableSlot = (void **)LGResolve_FilterTableSlot();
    if (!filterTableSlot) {
        intptr_t slide = getSlide();
        filterTableSlot = (void **)(kFB_FilterTable + slide);
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
        intptr_t slide = getSlide();
        gaussCtxSlot = (void **)(kFB_GaussianCtx + slide);
    }
    g_gaussCtxValue = (void *)*gaussCtxSlot;
    lglog("registerCustomFilter: g_gaussCtxValue = %p", g_gaussCtxValue);
    void **gaussVtable = (void **)*gaussCtxSlot;
    if (!gaussVtable) {
        lglog("registerCustomFilter: gaussian vtable not found");
        return false;
    }
    lglog("registerCustomFilter: cloning vtable from gaussian @ %p (via resolver)", gaussVtable);

    g_origGaussR13 = (Render13Fn)gaussVtable[13];
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
    g_customVtable[0]  = (void *)&ourIdentityStub;
    g_customVtable[13] = (void *)&ourCustomRender13;

    g_customCtx = mmap(NULL, 256, PROT_READ | PROT_WRITE,
                        MAP_ANON | MAP_PRIVATE, -1, 0);
    if (g_customCtx == MAP_FAILED) {
        lglog("registerCustomFilter: ctx mmap failed errno=%d", errno);
        munmap(g_customVtable, kVtableSlots * sizeof(void *));
        g_customVtable = nullptr;
        g_customCtx    = nullptr;
        return false;
    }
    *(void **)g_customCtx = g_customVtable;

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

    g_addFilter(atomId, g_customCtx);
    g_filterRegistered = true;
    lglog("registerCustomFilter: done ctx=%p vtable=%p slot13=%p",
          g_customCtx, g_customVtable, g_customVtable[13]);
    return true;
}

// dylib constructor, init symbol resolution and register custom filter
__attribute__((constructor))
static void tweakInit(void) {
    if (!LGSymResolverInit()) {
        lglog("init: LGSymResolverInit failed, QuartzCore not loaded yet?");
        return;
    }

    void *stopEnc = resolveWithFallback("stop_encoders",
                        LGResolve_StopEncoders(), kFB_StopEncoders);
    void *internA = resolveWithFallback("CAInternAtomWithCString",
                        LGResolve_CAInternAtomWithCString(), kFB_InternAtom);
    void *addF    = resolveWithFallback("add_filter",
                        LGResolve_AddFilter(), kFB_AddFilter);

    g_stopEncoders = (StopEncodersFn)stopEnc;
    g_internAtom   = (InternAtomFn)internA;
    g_addFilter    = (AddFilterFn)addF;

    lglog("init: stopEncoders=%p internAtom=%p addFilter=%p",
          stopEnc, internA, addF);

    g_outTex = new std::unordered_map<uint64_t, id<MTLTexture>>();

    registerCustomFilter();

    lglog("ready");
}
