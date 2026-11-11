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

// The original's vertex filters built a second time without SIMD, under
// reference_scalar_ names, so the oracle tests can check the port's scalar
// decoders against the original's scalar ones, which round differently
// from its SIMD ones. They convert NaN and out-of-range floats to int as
// x86 does, which undefined-behaviour checks would stop.
extern "C"
{
	void reference_scalar_decodeFilterOct(void* buffer, size_t count, size_t stride);
	void reference_scalar_decodeFilterQuat(void* buffer, size_t count, size_t stride);
	void reference_scalar_decodeFilterExp(void* buffer, size_t count, size_t stride);
	void reference_scalar_decodeFilterColor(void* buffer, size_t count, size_t stride);
	void reference_scalar_encodeFilterOct(void* destination, size_t count, size_t stride, int bits,
		const float* data);
	void reference_scalar_encodeFilterQuat(void* destination, size_t count, size_t stride, int bits,
		const float* data);
	void reference_scalar_encodeFilterExp(void* destination, size_t count, size_t stride, int bits,
		const float* data, enum meshopt_EncodeExpMode mode);
	void reference_scalar_encodeFilterColor(void* destination, size_t count, size_t stride, int bits,
		const float* data);
}

#pragma clang attribute push(__attribute__((no_sanitize("undefined"))), \
	apply_to = function)
#define MESHOPTIMIZER_NO_SIMD
#define meshopt reference_scalar_filter
#define meshopt_decodeFilterOct reference_scalar_decodeFilterOct
#define meshopt_decodeFilterQuat reference_scalar_decodeFilterQuat
#define meshopt_decodeFilterExp reference_scalar_decodeFilterExp
#define meshopt_decodeFilterColor reference_scalar_decodeFilterColor
#define meshopt_encodeFilterOct reference_scalar_encodeFilterOct
#define meshopt_encodeFilterQuat reference_scalar_encodeFilterQuat
#define meshopt_encodeFilterExp reference_scalar_encodeFilterExp
#define meshopt_encodeFilterColor reference_scalar_encodeFilterColor
#include "vertexfilter.cpp"
#undef meshopt_encodeFilterColor
#undef meshopt_encodeFilterExp
#undef meshopt_encodeFilterQuat
#undef meshopt_encodeFilterOct
#undef meshopt_decodeFilterColor
#undef meshopt_decodeFilterExp
#undef meshopt_decodeFilterQuat
#undef meshopt_decodeFilterOct
#undef meshopt
#undef MESHOPTIMIZER_NO_SIMD
#pragma clang attribute pop
