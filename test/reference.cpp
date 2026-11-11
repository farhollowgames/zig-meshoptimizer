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

// The original's vertex codec built a second time without SIMD, under
// reference_scalar_ names, so the oracle tests can check the port's scalar
// decoder against the original's scalar one: on some malformed buffers the
// original's scalar and SIMD decoders return different errors.
extern "C"
{
	size_t reference_scalar_encodeVertexBuffer(unsigned char* buffer, size_t buffer_size, const void* vertices, size_t vertex_count, size_t vertex_size);
	size_t reference_scalar_encodeVertexBufferBound(size_t vertex_count, size_t vertex_size);
	size_t reference_scalar_encodeVertexBufferLevel(unsigned char* buffer, size_t buffer_size, const void* vertices, size_t vertex_count, size_t vertex_size, int level, int version);
	void reference_scalar_encodeVertexVersion(int version);
	int reference_scalar_decodeVertexBuffer(void* destination, size_t vertex_count, size_t vertex_size, const unsigned char* buffer, size_t buffer_size);
	int reference_scalar_decodeVertexVersion(const unsigned char* buffer, size_t buffer_size);
}

#define MESHOPTIMIZER_NO_SIMD
#define meshopt reference_scalar
#define meshopt_encodeVertexBuffer reference_scalar_encodeVertexBuffer
#define meshopt_encodeVertexBufferBound reference_scalar_encodeVertexBufferBound
#define meshopt_encodeVertexBufferLevel reference_scalar_encodeVertexBufferLevel
#define meshopt_encodeVertexVersion reference_scalar_encodeVertexVersion
#define meshopt_decodeVertexBuffer reference_scalar_decodeVertexBuffer
#define meshopt_decodeVertexVersion reference_scalar_decodeVertexVersion
#include "vertexcodec.cpp"
#undef meshopt_decodeVertexVersion
#undef meshopt_decodeVertexBuffer
#undef meshopt_encodeVertexVersion
#undef meshopt_encodeVertexBufferLevel
#undef meshopt_encodeVertexBufferBound
#undef meshopt_encodeVertexBuffer
#undef meshopt
#undef MESHOPTIMIZER_NO_SIMD
