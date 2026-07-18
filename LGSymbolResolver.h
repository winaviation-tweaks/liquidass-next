
#import <Foundation/Foundation.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

bool LGSymResolverInit(void);

void *LGSymResolveExported(const char *symbolName);

void *LGSymScanText(const uint8_t *pattern, const char *mask,
                    size_t patternLen);

void *LGSymDecodeAdrpAdd(void *adrpInstrAddr);
void *LGSymDecodeAdrpLdr(void *adrpInstrAddr);

void *LGResolve_CAInternAtomWithCString(void);
void *LGResolve_AddFilter(void);
void *LGResolve_StopEncoders(void);
void **LGResolve_FilterTableSlot(void); // &CA::Render::filter_table
void **LGResolve_GaussianCtxSlot(void); // &gaussian_blur_filter ctx ptr

// -1 if unresolvable (0xaa8 on 15.8.8, 0xb38 on 16.x)
ptrdiff_t LGResolve_MetalCmdBufOffset(void);

// -1 if not found. vtable is gaussian's FilterSubclass dispatch table.
int LGResolve_RenderVtableSlot(void *const *vtable, int maxSlots);

void LGSymResolverSaveCache(void);

bool LGSymAddressInQuartzCoreImage(void *addr);

// pac helpers. LGSymMakeCallable signs pointers with IA key and LGSymStripCode strips them
void *LGSymMakeCallable(void *codeAddr);
void *LGSymStripCode(void *codeAddr);

#ifdef __cplusplus
}
#endif
