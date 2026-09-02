#ifndef SWIFTVLC_POST_PIN_STABILITY_COMPAT_H
#define SWIFTVLC_POST_PIN_STABILITY_COMPAT_H

#include <stddef.h>

#ifdef __cplusplus
# define restrict __restrict__
#endif

void *swiftvlc_validation_memrchr(const void *, int, size_t);
#define memrchr swiftvlc_validation_memrchr

#endif
