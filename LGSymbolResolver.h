
#import <Foundation/Foundation.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

bool LGSymResolverInit(void);

void *LGSymResolveExported(const char *symbolName);

void *LGSymScanText(const uint8_t *pattern, const char *mask, size_t patternLen);

void *LGSymDecodeAdrpAdd(void *adrpInstrAddr);
void *LGSymDecodeAdrpLdr(void *adrpInstrAddr);

void  *LGResolve_CAInternAtomWithCString(void);
void  *LGResolve_AddFilter(void);
void  *LGResolve_StopEncoders(void);
void **LGResolve_FilterTableSlot(void);
void **LGResolve_GaussianCtxSlot(void);

void LGSymResolverSaveCache(void);

#ifdef __cplusplus
}
#endif
