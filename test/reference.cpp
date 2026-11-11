// meshoptimizer.h's inline C++ functions, under C names the oracle tests and
// the benchmark can call.
#include "meshoptimizer.h"

extern "C" int reference_quantizeUnorm(float v, int N)
{
	return meshopt_quantizeUnorm(v, N);
}

extern "C" int reference_quantizeSnorm(float v, int N)
{
	return meshopt_quantizeSnorm(v, N);
}

// The system's libm functions the original calls, which test/libm_redirect.h
// renames to these: a binary Zig links would otherwise bind the original's
// calls to compiler_rt's versions, not the libm a normal build of it uses.
#ifdef __linux__
#include <dlfcn.h>

static void* systemLibm()
{
	static void* handle = dlopen("libm.so.6", RTLD_NOW);
	return handle;
}

extern "C" float reference_cosf(float x)
{
	static float (*f)(float) = (float (*)(float))dlsym(systemLibm(), "cosf");
	return f(x);
}

extern "C" float reference_log2f(float x)
{
	static float (*f)(float) = (float (*)(float))dlsym(systemLibm(), "log2f");
	return f(x);
}
#else
#include <math.h>

extern "C" float reference_cosf(float x)
{
	return cosf(x);
}

extern "C" float reference_log2f(float x)
{
	return log2f(x);
}
#endif
