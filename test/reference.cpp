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

// The same over arrays, so the benchmark times the inline code as a caller's
// loop has it, without a call per value.
extern "C" void reference_quantizeUnormArray(int* destination, const float* values, size_t count, int N)
{
	for (size_t i = 0; i < count; ++i)
		destination[i] = meshopt_quantizeUnorm(values[i], N);
}

extern "C" void reference_quantizeSnormArray(int* destination, const float* values, size_t count, int N)
{
	for (size_t i = 0; i < count; ++i)
		destination[i] = meshopt_quantizeSnorm(values[i], N);
}

extern "C" int reference_version()
{
	return MESHOPTIMIZER_VERSION;
}

// simplifier.cpp defines this without a declaration in the header, so with
// C++ linkage.
size_t meshopt_simplifyEdge(unsigned int* destination, const unsigned int* indices, size_t index_count, const float* vertex_positions_data, size_t vertex_count, size_t vertex_positions_stride, const float* vertex_attributes_data, size_t vertex_attributes_stride, const float* attribute_weights, size_t attribute_count, const unsigned char* vertex_lock, size_t target_index_count, float target_error, unsigned int options, float* out_result_error);

extern "C" size_t reference_simplifyEdge(unsigned int* destination, const unsigned int* indices, size_t index_count, const float* vertex_positions_data, size_t vertex_count, size_t vertex_positions_stride, const float* vertex_attributes_data, size_t vertex_attributes_stride, const float* attribute_weights, size_t attribute_count, const unsigned char* vertex_lock, size_t target_index_count, float target_error, unsigned int options, float* out_result_error)
{
	return meshopt_simplifyEdge(destination, indices, index_count, vertex_positions_data, vertex_count, vertex_positions_stride, vertex_attributes_data, vertex_attributes_stride, attribute_weights, attribute_count, vertex_lock, target_index_count, target_error, options, out_result_error);
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
