
#import "LGSymbolResolver.h"
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>

// symbol resolver logger
static void rlog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void rlog(const char *fmt, ...) {
    FILE *f = fopen("/tmp/liquidglass.log", "a");
    if (!f) return;
    fputs("[LGSYM] ", f);
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
    fputc('\n', f);
    fclose(f);
}

static uint8_t  *g_qcTextBase  = nullptr;
static size_t    g_qcTextSize  = 0;
static uint8_t  *g_qcImageLo   = nullptr; // full mapped image span, all segments
static uint8_t  *g_qcImageHi   = nullptr;
static intptr_t  g_qcSlide     = 0;
static bool      g_inited      = false;

// must call once before other resolver functions
bool LGSymResolverInit(void) {
    if (g_inited) return true;

    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, "QuartzCore")) continue;

        g_qcSlide = _dyld_get_image_vmaddr_slide(i);
        const struct mach_header_64 *hdr =
            (const struct mach_header_64 *)_dyld_get_image_header(i);

        unsigned long textSize = 0;
        uint8_t *textData = getsegmentdata((struct mach_header_64 *)hdr,
                                           "__TEXT", &textSize);
        if (textData) {
            g_qcTextBase = textData;
            g_qcTextSize = textSize;
        }

        const uint8_t *cmdPtr = (const uint8_t *)hdr + sizeof(struct mach_header_64);
        for (uint32_t c = 0; c < hdr->ncmds; c++) {
            const struct load_command *lc = (const struct load_command *)cmdPtr;
            if (lc->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *seg =
                    (const struct segment_command_64 *)lc;
                uint8_t *segLo = (uint8_t *)(seg->vmaddr + g_qcSlide);
                uint8_t *segHi = segLo + seg->vmsize;
                if (!g_qcImageLo || segLo < g_qcImageLo) g_qcImageLo = segLo;
                if (!g_qcImageHi || segHi > g_qcImageHi) g_qcImageHi = segHi;
            }
            cmdPtr += lc->cmdsize;
        }

        g_inited = (g_qcTextBase != nullptr);
        rlog("init: QuartzCore slide=%#tx __TEXT=%p size=%#zx fullImage=[%p,%p)",
             g_qcSlide, g_qcTextBase, g_qcTextSize, g_qcImageLo, g_qcImageHi);
        return g_inited;
    }
    rlog("init: QuartzCore image not found");
    return false;
}

void *LGSymResolveExported(const char *symbolName) {
    void *sym = dlsym(RTLD_DEFAULT, symbolName);
    rlog("dlsym(%s) = %p", symbolName, sym);
    return sym;
}

static uint8_t *rawScan(const uint8_t *needle, size_t needleLen,
                        uint8_t *start, size_t len) {
    if (needleLen == 0 || len < needleLen) return nullptr;
    uint8_t first = needle[0];
    uint8_t *end = start + len - needleLen;
    for (uint8_t *p = start; p <= end; p++) {
        p = (uint8_t *)memchr(p, first, end - p + 1);
        if (!p) return nullptr;
        if (memcmp(p, needle, needleLen) == 0) return p;
    }
    return nullptr;
}

// pattern scan with mask, mask[i]='x' means match, '?' means wildcard
void *LGSymScanText(const uint8_t *pattern, const char *mask, size_t patternLen) {
    if (!g_inited) return nullptr;
    uint8_t *end = g_qcTextBase + g_qcTextSize - patternLen;
    for (uint8_t *p = g_qcTextBase; p <= end; p++) {
        bool match = true;
        for (size_t i = 0; i < patternLen; i++) {
            if (mask[i] == 'x' && p[i] != pattern[i]) { match = false; break; }
        }
        if (match) return p;
    }
    return nullptr;
}

static uint8_t *findCString(const char *str) {
    if (!g_inited) return nullptr;
    size_t len = strlen(str) + 1; // include NUL, anchors more precisely
    return rawScan((const uint8_t *)str, len, g_qcTextBase, g_qcTextSize);
}

static inline bool isADRP(uint32_t instr) {
    return (instr & 0x9F000000) == 0x90000000;
}
static inline bool isADD_imm(uint32_t instr) {
    return (instr & 0x7F800000) == 0x11000000;
}
static inline bool isLDR_uoff64(uint32_t instr) {
    return (instr & 0xFFC00000) == 0xF9400000;
}
static inline bool isBL(uint32_t instr) {
    return (instr & 0xFC000000) == 0x94000000;
}
static inline bool isMOVZ_w0(uint32_t instr) {
    return (instr & 0xFF800000) == 0x52800000 && (instr & 0x1F) == 0;
}
static inline uint32_t decodeMOVZimm16(uint32_t instr) {
    return (instr >> 5) & 0xFFFF;
}
static inline bool isPACIBSP(uint32_t instr) { return instr == 0xD503237F; }

static inline bool isSTP_preindex_SP_neg(uint32_t instr) {
    return ((instr & 0xFFC00000) == 0xA9800000) &&
           (((instr >> 5) & 0x1F) == 31)         &&
           ((instr & 0x200000) != 0);               // imm7 MSB = 1 -> negative
}

static inline bool isFunctionPrologue(uint32_t instr) {
    return isPACIBSP(instr) || isSTP_preindex_SP_neg(instr);
}

static inline bool isSUBsp(uint32_t instr) {
    return (instr & 0xFF8003FF) == 0xD10003FF; // SUB(imm) 64, Rd=Rn=SP
}
static inline bool isLDRSTR_uimm64(uint32_t instr) {
    return (instr & 0xFF800000) == 0xF9000000;
}
static inline bool isMOVreg(uint32_t instr) {
    return (instr & 0xFFE0FFE0) == 0xAA0003E0; // MOV Xd,Xn
}

static int64_t signExtend(uint64_t v, int bits) {
    uint64_t m = 1ULL << (bits - 1);
    return (int64_t)((v ^ m) - m);
}

void *LGSymDecodeAdrpAdd(void *adrpInstrAddr) {
    uint32_t *p = (uint32_t *)adrpInstrAddr;
    if (!isADRP(p[0])) { rlog("decodeAdrpAdd: not ADRP at %p", p); return nullptr; }
    if (!isADD_imm(p[1])) { rlog("decodeAdrpAdd: not ADD at %p", p + 1); return nullptr; }

    uint32_t adrp = p[0], add = p[1];
    uint64_t immlo = (adrp >> 29) & 0x3;
    uint64_t immhi = (adrp >> 5)  & 0x7FFFF;
    int64_t  pageOff = signExtend((immhi << 2) | immlo, 21) << 12;

    uint64_t pc = (uint64_t)p;
    uint64_t page = (pc & ~0xFFFULL) + pageOff;

    uint64_t imm12 = (add >> 10) & 0xFFF;
    uint64_t shift = (add >> 22) & 0x1;
    if (shift) imm12 <<= 12;

    return (void *)(page + imm12);
}

void *LGSymDecodeAdrpLdr(void *adrpInstrAddr) {
    uint32_t *p = (uint32_t *)adrpInstrAddr;
    if (!isADRP(p[0])) { rlog("decodeAdrpLdr: not ADRP at %p", p); return nullptr; }
    if (!isLDR_uoff64(p[1])) { rlog("decodeAdrpLdr: not LDR at %p", p + 1); return nullptr; }

    uint32_t adrp = p[0], ldr = p[1];
    uint64_t immlo = (adrp >> 29) & 0x3;
    uint64_t immhi = (adrp >> 5)  & 0x7FFFF;
    int64_t  pageOff = signExtend((immhi << 2) | immlo, 21) << 12;

    uint64_t pc = (uint64_t)p;
    uint64_t page = (pc & ~0xFFFULL) + pageOff;

    uint64_t imm12 = (ldr >> 10) & 0xFFF;
    imm12 <<= 3;

    return (void *)(page + imm12);
}

static uint8_t *findFunctionStartBackward(uint8_t *withinFunc, size_t maxWindow) {
    uint32_t *p   = (uint32_t *)withinFunc;
    uint32_t *lim = (uint32_t *)(withinFunc - maxWindow);
    for (; p >= lim && (uint8_t *)p >= g_qcTextBase; p--) {
        if (!isFunctionPrologue(*p)) continue;
        if (isSTP_preindex_SP_neg(*p) &&
            p > (uint32_t *)g_qcTextBase &&
            isPACIBSP(*(p - 1))) {
            return (uint8_t *)(p - 1); // PACIBSP is the true entry point
        }
        return (uint8_t *)p;
    }
    return nullptr;
}

// try dlsym first, fall back to prologue scan
void *LGResolve_CAInternAtomWithCString(void) {
    void *sym = LGSymResolveExported("_CAInternAtomWithCString");
    if (sym) return sym;

    if (!g_inited) return nullptr;

    uint32_t *base  = (uint32_t *)g_qcTextBase;
    uint32_t *limit = (uint32_t *)(g_qcTextBase + g_qcTextSize) - 6;

    for (uint32_t *p = base; p < limit; p++) {
        if (p[0] != 0xA9BE4FF4u) continue; // stp x20,x19,[sp,#-0x20]!
        if (p[1] != 0xA9017BFDu) continue; // stp x29,x30,[sp,#0x10]
        if (p[2] != 0x910043FDu) continue; // add x29,sp,#0x10
        if (p[3] != 0xAA0003F3u) continue; // mov x19,x0
        if ((p[4] & 0xFC000000u) != 0x94000000u) continue; // not BL
        if ((p[4] & 0x02000000u) == 0)           continue; // positive -> skip
        if (p[5] != 0xAA0003F4u) continue; // mov x20,x0

        void *result = (void *)p;
        rlog("CAInternAtom: found via prologue scan -> %p", result);
        return result;
    }

    rlog("CAInternAtom: prologue scan found no match");
    return nullptr;
}

// atom values aint stable across builds, so gaussian is found by cluster
// position + runtime atom rather than a hardcoded value
struct GaussianSiteInfo {
    void *addFilterAddr   = nullptr;
    void *gaussianCtxPtr  = nullptr; // &gaussian_blur_filter (the static itself)
    void *filterTableSlot = nullptr; // &CA::Render::filter_table
    bool  valid = false;
};

static GaussianSiteInfo g_gaussianSite;
static bool g_gaussianSiteScanned = false;

// ADRP+ADD;movz w0,#imm;...;bl add_filter call, ctx must be 8 byte aligned to
// reject the structurally identical _x_log_ logging pattern
static void *matchAddFilterCallAt(uint32_t *p, uint32_t *limit, void **outCtx,
                                  uint32_t *outAtom) {
    if (!isMOVZ_w0(*p)) return nullptr;
    if (!isADRP(p[-2]) || !isADD_imm(p[-1])) return nullptr;

    void *ctx = LGSymDecodeAdrpAdd((void *)(p - 2));
    if (!ctx) return nullptr;
    if (((uintptr_t)ctx & 0x7) != 0) return nullptr; // not a static object ptr

    for (int i = 1; i <= 4; i++) {
        if (p + i >= limit) break;
        if (isBL(p[i])) {
            int32_t off = (int32_t)((p[i] & 0x03FFFFFF) << 2);
            off = (off << 4) >> 4;
            void *blTarget = (uint8_t *)(p + i) + off;
            *outCtx = ctx;
            if (outAtom) *outAtom = decodeMOVZimm16(*p);
            return blTarget;
        }
    }
    return nullptr;
}

static void scanGaussianSite(void) {
    if (g_gaussianSiteScanned) return;
    g_gaussianSiteScanned = true;
    if (!g_inited) return;

    uint32_t *base  = (uint32_t *)g_qcTextBase;
    uint32_t *limit = (uint32_t *)(g_qcTextBase + g_qcTextSize) - 8;

    typedef uint32_t (*InternFn)(const char *);
    InternFn intern = (InternFn)LGResolve_CAInternAtomWithCString();
    uint32_t gaussAtom = intern ? intern("gaussianBlur") : 0;
    rlog("scanGaussianSite: runtime gaussianBlur atom = 0x%x%s", gaussAtom,
         gaussAtom ? "" : " (intern unavailable -> positional fallback)");

    const ptrdiff_t kMaxClusterGap = 0x40 / 4; // instruction words
    const int kMinClusterLen = 4;

    for (uint32_t *p = base + 2; p < limit; p++) {
        void *firstCtx = nullptr; uint32_t firstAtom = 0;
        void *firstTarget = matchAddFilterCallAt(p, limit, &firstCtx, &firstAtom);
        if (!firstTarget) continue;

        uint32_t *matchAddrs[8];
        void     *matchCtxs[8];
        uint32_t  matchAtoms[8];
        int matchCount = 0;
        matchAddrs[matchCount] = p;
        matchCtxs[matchCount]  = firstCtx;
        matchAtoms[matchCount] = firstAtom;
        matchCount++;

        uint32_t *cursor = p;
        while (matchCount < 8) {
            uint32_t *searchStart = cursor + 1;
            uint32_t *searchEnd   = cursor + kMaxClusterGap;
            if (searchEnd > limit) searchEnd = limit;

            uint32_t *found = nullptr;
            void *foundCtx = nullptr; uint32_t foundAtom = 0;
            for (uint32_t *q = searchStart; q < searchEnd; q++) {
                void *t = matchAddFilterCallAt(q, limit, &foundCtx, &foundAtom);
                if (t == firstTarget) { found = q; break; }
            }
            if (!found) break; // cluster ends here
            matchAddrs[matchCount] = found;
            matchCtxs[matchCount]  = foundCtx;
            matchAtoms[matchCount] = foundAtom;
            matchCount++;
            cursor = found;
        }

        if (matchCount < kMinClusterLen) continue; // too short, keep scanning

        int gaussIdx = -1;
        if (gaussAtom) {
            for (int i = 0; i < matchCount; i++) {
                if (matchAtoms[i] == gaussAtom) { gaussIdx = i; break; }
            }
            if (gaussIdx < 0) {
                rlog("scanGaussianSite: cluster @%p (len %d) lacks gaussian atom 0x%x, skipping",
                     p, matchCount, gaussAtom);
                continue;
            }
        } else {
            gaussIdx = (matchCount > 1) ? 1 : 0; // positional fallback
        }

        void *gaussianCtx = matchCtxs[gaussIdx];

        void *filterTableSlot = nullptr;
        uint32_t *clusterStart = matchAddrs[0];
        for (uint32_t *r = clusterStart - 2; r > clusterStart - 2 - 24 && r > base; r--) {
            if (isADRP(*r) && r + 1 < limit && isLDR_uoff64(r[1])) {
                filterTableSlot = LGSymDecodeAdrpLdr((void *)r);
                break;
            }
        }

        g_gaussianSite.addFilterAddr   = firstTarget;
        g_gaussianSite.gaussianCtxPtr  = gaussianCtx;
        g_gaussianSite.filterTableSlot = filterTableSlot;
        g_gaussianSite.valid = true;

        rlog("scanGaussianSite: confirmed cluster of %d calls, start=%p gaussIdx=%d atom=0x%x",
             matchCount, clusterStart, gaussIdx, matchAtoms[gaussIdx]);
        rlog("  add_filter = %p", firstTarget);
        rlog("  gaussian ctx = %p", gaussianCtx);
        rlog("  filter_table slot = %p", filterTableSlot);
        return;
    }
    rlog("scanGaussianSite: no confirmed add_filter cluster found");
}

void *LGResolve_AddFilter(void) {
    scanGaussianSite();
    return g_gaussianSite.addFilterAddr;
}

void **LGResolve_GaussianCtxSlot(void) {
    scanGaussianSite();
    return (void **)g_gaussianSite.gaussianCtxPtr;
}

void **LGResolve_FilterTableSlot(void) {
    scanGaussianSite();
    return (void **)g_gaussianSite.filterTableSlot;
}

void *LGResolve_StopEncoders(void) {
    if (!g_inited) return nullptr;

    uint8_t *strLoc = findCString("!memoryless_in_use ()");
    if (!strLoc) { rlog("stop_encoders: anchor string not found"); return nullptr; }
    rlog("stop_encoders: anchor string at %p", strLoc);

    uint32_t *base = (uint32_t *)g_qcTextBase;
    uint32_t *end  = (uint32_t *)(g_qcTextBase + g_qcTextSize) - 1;
    void *xrefSite = nullptr;
    for (uint32_t *p = base; p < end; p++) {
        if (!isADRP(*p) || !isADD_imm(p[1])) continue;
        void *decoded = LGSymDecodeAdrpAdd((void *)p);
        if (decoded == (void *)strLoc) { xrefSite = (void *)p; break; }
    }
    if (!xrefSite) { rlog("stop_encoders: no xref to anchor string found"); return nullptr; }
    rlog("stop_encoders: xref site at %p", xrefSite);

    uint8_t *fnStart = findFunctionStartBackward((uint8_t *)xrefSite, 0x800);
    if (!fnStart) { rlog("stop_encoders: prologue not found within window"); return nullptr; }

    rlog("stop_encoders: resolved entry = %p", fnStart);
    return fnStart;
}

// MetalContext cmdbuf field offset (0xaa8 on 15.8.8, 0xb38 on 16.x)
ptrdiff_t LGResolve_MetalCmdBufOffset(void) {
    if (!g_inited) return -1;

    uint8_t *strLoc = findCString("Command buffer allocation failed!\n");
    if (!strLoc) { rlog("cmdbuf: anchor string not found"); return -1; }
    rlog("cmdbuf: anchor string at %p", strLoc);

    uint32_t *base = (uint32_t *)g_qcTextBase;
    uint32_t *end  = (uint32_t *)(g_qcTextBase + g_qcTextSize) - 1;
    void *xrefSite = nullptr;
    for (uint32_t *p = base; p < end; p++) {
        if (!isADRP(*p) || !isADD_imm(p[1])) continue;
        if (LGSymDecodeAdrpAdd((void *)p) == (void *)strLoc) { xrefSite = (void *)p; break; }
    }
    if (!xrefSite) { rlog("cmdbuf: no xref to anchor string found"); return -1; }
    rlog("cmdbuf: xref site at %p", xrefSite);

    // start_command_buffer opens with `sub sp,sp,#imm`, accept that as a prologue too
    uint8_t *fnStart = nullptr;
    {
        uint32_t *p   = (uint32_t *)xrefSite;
        uint32_t *lim = (uint32_t *)((uint8_t *)xrefSite - 0x1000);
        for (; p >= lim && (uint8_t *)p >= g_qcTextBase; p--) {
            if (isPACIBSP(*p) || isSTP_preindex_SP_neg(*p) || isSUBsp(*p)) {
                if ((isSTP_preindex_SP_neg(*p) || isSUBsp(*p)) &&
                    p > (uint32_t *)g_qcTextBase && isPACIBSP(*(p - 1)))
                    fnStart = (uint8_t *)(p - 1);
                else
                    fnStart = (uint8_t *)p;
                break;
            }
        }
    }
    if (!fnStart) { rlog("cmdbuf: prologue not found within window"); return -1; }
    rlog("cmdbuf: start_command_buffer entry = %p", fnStart);

    uint32_t *q = (uint32_t *)fnStart;
    uint32_t thisMask = 1u; // bit0 = x0 holds `this` at entry
    for (int i = 0; i < 48 && (q + i) < end; i++) {
        uint32_t ins = q[i];
        if (isMOVreg(ins)) {
            uint32_t src = (ins >> 16) & 0x1f, dst = ins & 0x1f;
            if ((thisMask >> src) & 1) thisMask |= (1u << dst);
            else                       thisMask &= ~(1u << dst);
            continue;
        }
        if (isLDRSTR_uimm64(ins)) {
            uint32_t bn = (ins >> 5) & 0x1f, rt = ins & 0x1f;
            uint32_t imm = ((ins >> 10) & 0xfff) << 3;
            if (((thisMask >> bn) & 1) && imm >= 0x400) {
                rlog("cmdbuf: MetalContext command-buffer offset = %#x", imm);
                return (ptrdiff_t)imm;
            }
            if (ins & 0x00400000) thisMask &= ~(1u << rt); // LDR clobbers Rt
        }
    }
    rlog("cmdbuf: command-buffer field access not found");
    return -1;
}

// base class BlurFilter::render forwarder sits at slot K and dispatches to
// vtable[K+1], the derived render CA actually invokes (12 on 15.8.8, 13 on 16.x)
int LGResolve_RenderVtableSlot(void * const *vtable, int maxSlots) {
    if (!vtable) return -1;

    for (int i = 0; i + 1 < maxSlots; i++) {
        uint32_t *fn = (uint32_t *)vtable[i];
        if (!fn || !LGSymAddressInQuartzCoreImage((void *)fn)) continue;

        for (int k = 0; k + 1 < 20; k++) {
            uint32_t ins = fn[k];
            if (ins == 0xD65F03C0u) break;         // ret -> end of function
            if (ins != 0xF9400008u) continue;      // ldr x8,[x0]
            if ((fn[k + 1] & 0xFFC003FFu) != 0xF9400108u) continue; // ldr x8,[x8,#imm]

            int targetSlot = (int)((fn[k + 1] >> 10) & 0xFFFu); // imm/8
            if (targetSlot != i + 1) continue;     // forward-to-next-slot invariant

            bool dispatched = false;
            for (int j = k + 2; j < k + 16; j++) {
                uint32_t b = fn[j];
                if (b == 0xD61F0100u || b == 0xD63F0100u) { dispatched = true; break; } // br/blr x8
                if (b == 0xD65F03C0u) break;
            }
            if (!dispatched) continue;

            rlog("render-slot: forwarder at vtable[%d] -> render vtable[%d]", i, targetSlot);
            return targetSlot;
        }
    }
    rlog("render-slot: render forwarder not found (checked %d slots)", maxSlots);
    return -1;
}

bool LGSymAddressInQuartzCoreImage(void *addr) {
    if (!g_inited || !addr) return false;
    return (addr >= (void *)g_qcImageLo && addr < (void *)g_qcImageHi);
}

void LGSymResolverSaveCache(void) {
    NSBundle *qc = [NSBundle bundleWithPath:@"/System/Library/Frameworks/QuartzCore.framework"];
    NSString *version = qc.infoDictionary[@"CFBundleVersion"] ?: @"unknown";

    NSDictionary *cache = @{
        @"qcVersion"      : version,
        @"addFilter"      : @((uintptr_t)LGResolve_AddFilter() - g_qcSlide),
        @"stopEncoders"   : @((uintptr_t)LGResolve_StopEncoders() - g_qcSlide),
        @"gaussianCtxSlot": @((uintptr_t)LGResolve_GaussianCtxSlot() - g_qcSlide),
        @"filterTableSlot": @((uintptr_t)LGResolve_FilterTableSlot() - g_qcSlide),
    };
    [cache writeToFile:@"/tmp/lg_symcache.plist" atomically:YES];
    rlog("cache saved for QuartzCore version %s", version.UTF8String);
}
