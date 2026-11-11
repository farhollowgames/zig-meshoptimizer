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
