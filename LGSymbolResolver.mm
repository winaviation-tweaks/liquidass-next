
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
        g_inited = (g_qcTextBase != nullptr);
        rlog("init: QuartzCore slide=%#tx __TEXT=%p size=%#zx",
             g_qcSlide, g_qcTextBase, g_qcTextSize);
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

// pattern scan with mask - mask[i]='x' means match, '?' means wildcard
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
    return (instr & 0xFFC00000) == 0xF9400000; // LDR Xt,[Xn,#imm12] 64-bit
}
static inline bool isBL(uint32_t instr) {
    return (instr & 0xFC000000) == 0x94000000;
}
static inline bool isMOVZ_w0(uint32_t instr) {
    return (instr & 0xFF800000) == 0x52800000 && (instr & 0x1F) == 0;
}
static inline bool isPACIBSP(uint32_t instr) { return instr == 0xD503237F; }

static inline bool isSTP_preindex_SP_neg(uint32_t instr) {
    return ((instr & 0xFFC00000) == 0xA9800000) && // pre-indexed STP 64-bit
           (((instr >> 5) & 0x1F) == 31)         && // Rn = SP
           ((instr & 0x200000) != 0);               // imm7 MSB = 1 -> negative
}

static inline bool isFunctionPrologue(uint32_t instr) {
    return isPACIBSP(instr) || isSTP_preindex_SP_neg(instr);
}

static int64_t signExtend(uint64_t v, int bits) {
    uint64_t m = 1ULL << (bits - 1);
    return (int64_t)((v ^ m) - m);
}

// decode ADRP+ADD pair to get absolute address
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

// decode ADRP+LDR pair to get pointer address
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
    imm12 <<= 3; // LDR 64-bit scales imm12 by 8

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
        if (p[0] != 0xA9BE4FF4u) continue;
        if (p[1] != 0xA9017BFDu) continue;
        if (p[2] != 0x910043FDu) continue;
        if (p[3] != 0xAA0003F3u) continue;
        if ((p[4] & 0xFC000000u) != 0x94000000u) continue; // not BL
        if ((p[4] & 0x02000000u) == 0)           continue; // positive -> skip
        if (p[5] != 0xAA0003F4u) continue;

        void *result = (void *)p;
        rlog("CAInternAtom: found via prologue scan -> %p", result);
        return result;
    }

    rlog("CAInternAtom: prologue scan found no match");
    return nullptr;
}

struct GaussianSiteInfo {
    void *addFilterAddr  = nullptr;
    void *gaussianCtxPtr = nullptr; // &gaussian_blur_filter (the static itself)
    void *filterTableSlot = nullptr; // &CA::Render::filter_table
    bool  valid = false;
};

static GaussianSiteInfo g_gaussianSite;
static bool g_gaussianSiteScanned = false;

static void scanGaussianSite(void) {
    if (g_gaussianSiteScanned) return;
    g_gaussianSiteScanned = true;
    if (!g_inited) return;

    uint32_t *base = (uint32_t *)g_qcTextBase;
    uint32_t *limit = (uint32_t *)(g_qcTextBase + g_qcTextSize) - 8;

    for (uint32_t *p = base; p < limit; p++) {
        if (!isMOVZ_w0(*p)) continue;
        uint32_t imm16 = (*p >> 5) & 0xFFFF;
        if (imm16 != 0xe2) continue;

        if (p < base + 2) continue;
        if (!isADRP(p[-2]) || !isADD_imm(p[-1])) continue;

        void *blTarget = nullptr;
        for (int i = 1; i <= 4; i++) {
            if (isBL(p[i])) {
                int32_t off = (int32_t)((p[i] & 0x03FFFFFF) << 2);
                off = (off << 4) >> 4; // sign-extend 26-bit imm (already <<2)
                blTarget = (uint8_t *)(p + i) + off;
                break;
            }
        }
        if (!blTarget) continue;

        void *gaussianCtx = LGSymDecodeAdrpAdd((void *)(p - 2));
        if (!gaussianCtx) continue;

        void *filterTableSlot = nullptr;
        for (uint32_t *q = p - 2; q > p - 2 - 24 && q > base; q--) {
            if (isADRP(*q) && q + 1 < limit && isLDR_uoff64(q[1])) {
                filterTableSlot = LGSymDecodeAdrpLdr((void *)q);
                break;
            }
        }

        g_gaussianSite.addFilterAddr   = blTarget;
        g_gaussianSite.gaussianCtxPtr  = gaussianCtx;
        g_gaussianSite.filterTableSlot = filterTableSlot;
        g_gaussianSite.valid = true;

        rlog("scanGaussianSite: found mov-w0-0xe2 at %p", p);
        rlog("  add_filter = %p", blTarget);
        rlog("  gaussian ctx = %p", gaussianCtx);
        rlog("  filter_table slot = %p", filterTableSlot);
        return;
    }
    rlog("scanGaussianSite: pattern not found");
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
