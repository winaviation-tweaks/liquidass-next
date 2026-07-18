# liquidass-next

test prototype for Liquid (Gl)ass 0.1.0b

currently hopefully works on all iOS 15 and iOS 16 versions. (every iOS 15 version and 16.7.x confirmed to work)

only works on A11 and lower since i've been running into PAC issues

## Overview

### Filter Registration

registers a privately named CAFilter type (`"dylv.liquidglass.refraction"`)
via `CA::Render::add_filter`

LiquidGlassSB's floating test view then uses this filter

### VTable Cloning

clones the gaussian FilterSubclass vtable as a starting point:

- **most slots**: filter generic helpers (DOD, ROI, bounds, can_render, etc) that work fine unmodded
- **slot 0 (identity)**: overridden to always return "not identity", preventing runtime caching as a no op
- **render slot**: custom compute injection, then calls the real gaussian render at scale 0 (passthrough) so CA's output routing and surface texture lifecycle stay correct

the render slot is NOT fixed across versions (slot 12 on 15.8.8, slot 13 on 16.x),
so it is resolved at runtime instead of hardcoded, see LGResolve_RenderVtableSlot

because this filter is ours, runtime caching is prevented by construction

## File Struct

### Tweak.mm

main backboardd tweak that implements the metal compute shader integration.
clears `/tmp/liquidglass.log` and logs an iOS version banner on load.

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
   - targets: `filter_table`, gaussian context struct (local statics which are fully stripped)
   - finds CODE that references the data via AOB scanning
   - decodes ARM64 ADRP+ADD / ADRP+LDR instruction pairs to recover absolute data address
   - position-independent, always computes correct address relative to actual mapping

### LGSymbolResolver.mm

impl of the three-tier symbol reso strat

**instruction decoders**:

- `isADRP(uint32_t)`
- `isADD_imm(uint32_t)`
- `isLDR_uoff64(uint32_t)`
- `isBL(uint32_t)`
- `isMOVZ_w0(uint32_t)` / `decodeMOVZimm16(uint32_t)`
- `isPACIBSP(uint32_t)`
- `isSTP_preindex_SP_neg(uint32_t)` / `isSUBsp(uint32_t)`
- `isLDRSTR_uimm64(uint32_t)` / `isMOVreg(uint32_t)`

**shared gaussian site scan** (feeds three resolvers):
locates the cluster of consecutive `add_filter` calls in `CA::Render::Filter::Filter`.
atom VALUES are not stable across builds (0xd8 on 15.8.8, 0xdf on 16.2, 0xe2 on
16.6/16.7), so it does NOT match a hardcoded atom, it matches the cluster and
finds gaussian inside it by its runtime atom. this single scan provides:

- add_filter address itself
- gaussian's context struct
- filter_table via instr decode rather than separate scans

**key resolvers:**

1. **CAInternAtomWithCString resolution**:
   - tier 1: dlsym (exported on some versions)
   - tier 2: prologue scan for unique 6-instr pattern
   - pattern: STP X20,X19 | STP X29,X30 | ADD X29,SP | MOV X19,X0 | BL __CAInternAtomWithCString | MOV X20,X0
   - it gave exactly 1 match on the tested builds (uhhh i lowk dont know if the same pattern works for every ios version)
   - negative-offset bl constraint eliminates forward calls

2. **stop_encoders resolution**:
   - string xref: locate literal assert message `"!memoryless_in_use ()"`
   - find ADRP+ADD pair computing string address
   - walk backward to function prologue (within 0x800 byte window)

3. **MetalCmdBufOffset resolution**:
   - string xref on `"Command buffer allocation failed!\n"` inside start_command_buffer
   - walk back to entry (accepts a `sub sp` prologue), then take the first `this`
   - relative 64 bit field load with a large immediate
   - thats the command buffer slot (0xaa8 on 15.8.8, 0xb38 on 16.x)

4. **RenderVtableSlot resolution**:
   - the baseclass BlurFilter::render forwarder stays at slot K and dispatches to `this->vtable[K+1]`
   - decode that to get the derived render slot without a hardcoded index

5. **AddFilter, GaussianCtxSlot, FilterTableSlot**:
   - all derived from single shared gaussian site scan

### LiquidGlassSB/Tweak.x

sb companion tweak implementing the floating draggable glass test view
uses our private filter type `"dylv.liquidglass.refraction"`

**idempotent filter application:**

- applyFilters fires from `didMoveToWindow` and `layoutSubviews` (both trigger repeatedly during drag)
- recreating filter objects each call causes CA to allocate new surface per instance
- without idempotency check: ping pong explosion causes OOM crash on backboardd side
- solution: skip if our filter is already set

**registration race re-commit:**

- our filter type only exists in backboardd's filter_table, which only populates once the render server decodes its first filter
- registration can finish AFTER our filter was already decoded as "unknown", so the glass sometimes did not show up (intermittent, worse on iOS 15)
- fix: re-commit a fresh filter a few times over the first ~12s, whichever re-commit lands after registration resolves to our real type

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
    simd_float2 wallpaperOrigin;         // wallpaper offset
    simd_float2 samplingTransformX;      // backdrop -> screen mapping row 0
    simd_float2 samplingTransformY;      // backdrop -> screen mapping row 1
    simd_float2 samplingTransformOffset; // backdrop -> screen mapping translation
    float       samplingOrientation;     // 1..4 (UIImageOrientation)
    float       hasShapeMask;            // 0 or 1
} LGUniforms;
```

### Field Offsets

resolved at runtime or read via public API, nothing hardcoded per build:

- **MetalContext command buffer**: resolved dynamically (0xaa8 on 15.8.8, 0xb38 on 16.x)
- **Surface MTLTexture** (kSurfTexOffset, 0x58): stable across 15.8.8 and 16.x
- **device + texture width/height**: read straight off the MTLTexture via public Metal API (version independent), so no device/width/height offsets are needed

## Critical Implementation Details

### Filter Registration Timing

must NOT be called before `CA::Render::filter_table` is populated:

- `add_filter` creates `filter_table` when null
- `CA::Render::Filter::Filter` lazily registers all builtin filters only when `filter_table` IS null
- calling `add_filter` too early orphans the table with ONLY our entry and all system blur disappears (it actually looks good though, might make it a tweak lol)
- solution: poll until table exists, then add

### Custom Filter Type Name

- `"dylv.liquidglass.refraction"`

### Gaussian Context Value

critical distinction between two concepts:

1. **gaussCtxSlot**: pointer to the slot containing the gaussian context
2. **gaussCtxValue**: the actual ctx value (what gaussCtxSlot points to)

- this the `CAML::Context*` the gaussian uses to locate its output buffer

### Render Slot Behavior

- custom render impl called for every frame
- must call the original gauss render (saved from the resolved render slot)
- orig writes to correct compositor output slot and manages surface textures
- render slot is version specific (12 on 15.8.8, 13 on 16.x), resolved at runtime
- no skip/cache optimization possible (identity stub prevents it)

### Filter Table Persistence

the custom filter registration is:

- onetime insert into `CA::Render::filter_table`
- persists for lifetime of backboardd process
- if needed, can be re-registered via CFNotificationCenter observer (idempotent, re-registering same atom just overwrites table entry)

## Important Notes

- backboardd CPU can spike (~50-80%) while the floating view is dragged. isolation testing (down to a pure stock UIVisualEffectView with zero custom code) showed this is inherent to CABackdropLayer's live capture mechanism, not our impl's problems

## A12+ (arm64e) unsupported

the whole thing hinges on cloning the gaussian FilterSubclass vtable into a fresh mmap and pointing the filter ctx at it but arm64e makes that impossible, the object vptr and every vtable entry are PAC-signed with addr diversity, so relocating the vtable invalidates every sig. CA auths on dispatch and dies, thats exactly what PAC vtable hardening is designed to stop

everything tried on arm64e crashed, in order:
- clone as is: crashed at first dispatch in `CA::Render::Filter::evaluate_identity` (autda on our raw vptr)
- resign the vptr for our ctx and inject via an MSHookFunction hook on `GaussianBlurFilter::render` instead of cloning, got all the way to our render firing, but compositing needs the real gaussian render to run its blur pass, and that either did nothing (scale 0) or ran the full multipass blur, which readded blur additionally crashing the AGX driver (`blur_surface` -> bad intermediate tex) once our compute touches MetalContext

resigning all ~10-20 dispatched vtable slots by hand (each an exact or crash discriminator) is not really a good idea so arm64e is dropped. the arm64e slice detects itself at load (`__has_feature(ptrauth_calls)`) and returns immediately, leaving the device unmodded. A12+ needs a very different approach (no vtable relocation), revisiting if ever
