# liquidass-next

test prototype for Liquid (Gl)ass 0.1.0b

## Overview

### Filter Registration

registers a privately named CAFilter type (`"liquidGlassRefraction"`) via `CA::Render::add_filter`

LiquidGlassSB's floating test view then uses this filter

### VTable Cloning

clones GaussianBlurFilter vtable as a starting point:

- **slots 1-12, 14-19**: filter generic helpers (DOD, ROI, bounds, can_render, etc) that work fine unmodded
- **slot 0 (identity)**: overridden to always return "not identity", preventing runtime caching as a no op
- **slot 13 (render)**: custom compute injection, no original call nor restore

because this filter is ours, runtime caching is prevented by construction

## File Struct

### Tweak.mm

main backboardd tweak that implements the metal compute shader integration

### LGSymbolResolver.h

header defining the three-tier symbol reso strat

**three-tier strat** (in order of preference):

1. **dlsym()** for genuinely exported symbols
   - `_CAInternAtomWithCString` is a C function (leading underscore = exported C convention)
   - dlsym handles ASLR automatically, no manual slide math needed

2. **AOB sig scan**: for C++ methods not exported
   - examples: `CA::Render::add_filter`, `CA::OGL::MetalContext::stop_encoders`
   - scans for short byte sequences in QuartzCore's __TEXT segment
   - uses wildcard bytes for anything encoding absolute addresses/offsets
   - probably works across point releases due to stable function prologues

3. **code-following reso**: for static DATA
   - targets: `filter_table`, `gaussian_blur_filter`'s context struct (local statics which are fully stripped)
   - finds CODE that references the data via AOB scanning
   - decodes ARM64 ADRP+ADD / ADRP+LDR instruction pairs to recover absolute data address
   - position-independent, always computes correct address relative to actual mapping

resolved addresses then gets cached in `/tmp/lg_symcache.plist`

### LGSymbolResolver.mm

impl of the three-tier symbol reso strat

**instruction decoders**:

- `isADRP(uint32_t)`
- `isADD_imm(uint32_t)`
- `isLDR_uoff64(uint32_t)`
- `isBL(uint32_t)`
- `isMOVZ_w0(uint32_t)`
- `isPACIBSP(uint32_t)`
- `isSTP_preindex_SP_neg(uint32_t)`

**shared scan pattern** (sthree resolvers):
locates `mov w0, #0xe2 ; bl add_filter` call site for the gaussian filter. this single scan provides:

- add_filter address itself
- gaussian's context struct (`&gaussian_blur_filter`)
- filter_table via instr decode rather than separate scans

**key resolvers:**

1. **CAInternAtomWithCString resolution**:
   - tier 1: dlsym (exported on some versions)
   - tier 2: prologue scan for unique 6-instr pattern
   - pattern: STP X20,X19 | STP X29,X30 | ADD X29,SP | MOV X19,X0 | BL __CAInternAtomWithCString | MOV X20,X0
   - it gave exactly 1 match in 16.7.11 QuartzCore binary (uhhh i lowk dont know if the same pattern works for which else ios versions)
   - negative-offset bl constraint eliminates forward calls

2. **stop_encoders resolution**:
   - string xref: locate literal assert message `"!memoryless_in_use ()"`
   - find ADRP+ADD pair computing string address
   - walk backward to function prologue (within 0x800 byte window)

3. **AddFilter, GaussianCtxSlot, FilterTableSlot**:
   - all derived from single shared gaussian site scan

### LiquidGlassSB/Tweak.x

sb companion tweak implementing the floating draggable glass test view
uses our private filter type `"liquidGlassRefraction"`

**idempotent filter application:**

- applyFilters fires from `didMoveToWindow` and `layoutSubviews` (both trigger repeatedly during drag)
- recreating filter objects each call causes CA to allocate new surface per instance
- without idempotency check: ping pong explosion causes OOM crash on backboardd side
- solution: skip if our filter is already set

## Key Data Structures

### Uniforms (LGUniforms)

mirror struct in metal shader (layout must match exactly):

```c
typedef struct {
    simd_float2 resolution;              // surface texture size
    simd_float2 screenResolution;        // device screen in px
    simd_float2 cardOrigin;              // card topleft in screen space
    simd_float2 wallpaperResolution;     // backdrop texture size
    float       radius;                  // corner radius in px
    float       bezelWidth;              // glass edge zone width in px
    float       glassThickness;          // perpendicular glass depth for refraction
    float       refractionScale;         // global refraction multiplier
    float       refractiveIndex;         // IOR (1.0 = none, 1.5 = glass)
    float       specularOpacity;         // highlight brightness
    float       specularAngle;           // light direction in radians
    float       blur;                    // informational only (dropped it from liquidass)
    simd_float2 wallpaperOrigin;         // wallpaper offset
    simd_float2 samplingTransformX;      // backdrop -> screen mapping row 0
    simd_float2 samplingTransformY;      // backdrop -> screen mapping row 1
    simd_float2 samplingTransformOffset; // backdrop -> screen mapping translation
    float       samplingOrientation;     // 1..4 (UIImageOrientation)
    float       hasShapeMask;            // 0 or 1
} LGUniforms;
```

### Field Offsets

- **MetalContext offsets**:
  - kMtlDeviceOffset (0xb20): id<MTLDevice>
  - kMtlCmdBufOffset (0xb38): id<MTLCommandBuffer>
- **Surface offsets**:
  - kSurfTexOffset (0x58): id<MTLTexture>
  - kSurfWidthOffset (0x70): uint64_t
  - kSurfHeightOffset (0x78): uint64_t

## Critical Implementation Details

### Filter Registration Timing

must NOT be called before `CA::Render::filter_table` is populated:

- `add_filter` creates `filter_table` when null
- `CA::Render::Filter::Filter` lazily registers all builtin filters only when `filter_table` IS null
- calling `add_filter` too early orphans the table with ONLY our entry and all system blur disappears (it actually looks good though, might make it a tweak lol)
- solution: poll until table exists, then add

### Custom Filter Type Name

- `"dylv.liquidglass.refraction"`
- example collision values: gaussian=0xe2, varblur=0x217

### Gaussian Context Value

critical distinction between two concepts:

1. **gaussCtxSlot**: pointer to the slot containing the gaussian context
2. **gaussCtxValue**: the actual CONTEXT VALUE (what gaussCtxSlot points to)

- this the `CAML::Context*` the gaussian uses to locate its output buffer

### Render Slot 13 Behavior

- custom render impl called for every frame
- must call `g_origGaussR13` (original gauss slot 13)
- orig writes to correct compositor output slot
- properly manages surface textures
- no skip/cache optimization possible (identity stub prevents it)

### Symbol Resolution Fallback

hardcoded addresses in Tweak.mm are fallbacks only:

- used when resolver fails
- specific to iOS 16.7.11 QuartzCore, prolly diffs with model too
- when resolver succeeds, fallback addrs never touched

### Filter Table Persistence

the custom filter registration is:

- onetime insert into `CA::Render::filter_table`
- persists for lifetime of backboardd process
- if needed, can be re-registered via CFNotificationCenter observer (idempotent, re-registering same atom just overwrites table entry)

## Important Notes

- currently, it could cause horrendous battery drain and overheating, the backboardd process could spike up to 50% CPU (although still responsive) when the floating view is being dragged around
- graphical issues still exists, trying my best to fix them
