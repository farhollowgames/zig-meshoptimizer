// Included before each of the original's sources: its cosf and log2f calls
// go to the system's libm (test/reference.cpp), as in a normal build of it,
// where a binary Zig links would bind them to compiler_rt's versions.
#include <math.h>

#ifdef __cplusplus
extern "C" {
#endif
float reference_cosf(float x);
float reference_log2f(float x);
#ifdef __cplusplus
}
#endif

#define cosf reference_cosf
#define log2f reference_log2f
