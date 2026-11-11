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

// The original's default allocator back, as the other tests expect it: the
// cache off, then the header's default callbacks, which only C++ can name.
extern "C" void reference_resetAllocator()
{
	meshopt_setAllocatorCache(0, 0);
	meshopt_setAllocator(operator new, operator delete);
}

// The header's C++ templates for 16-bit indices, which widen them through
// meshopt_IndexAdapter, under C names: the oracle tests of the port's u16
// functions call these.

extern "C" size_t reference16_generateVertexRemap(unsigned int* destination, const unsigned short* indices, size_t index_count, const void* vertices, size_t vertex_count, size_t vertex_size)
{
	return meshopt_generateVertexRemap<unsigned short>(destination, indices, index_count, vertices, vertex_count, vertex_size);
}

extern "C" size_t reference16_generateVertexRemapMulti(unsigned int* destination, const unsigned short* indices, size_t index_count, size_t vertex_count, const meshopt_Stream* streams, size_t stream_count)
{
	return meshopt_generateVertexRemapMulti<unsigned short>(destination, indices, index_count, vertex_count, streams, stream_count);
}

extern "C" void reference16_remapIndexBuffer(unsigned short* destination, const unsigned short* indices, size_t index_count, const unsigned int* remap)
{
	meshopt_remapIndexBuffer<unsigned short>(destination, indices, index_count, remap);
}

extern "C" size_t reference16_filterIndexBuffer(unsigned short* destination, const unsigned short* indices, size_t index_count, const void* vertices, size_t vertex_count, size_t vertex_size, size_t vertex_stride)
{
	return meshopt_filterIndexBuffer<unsigned short>(destination, indices, index_count, vertices, vertex_count, vertex_size, vertex_stride);
}

extern "C" size_t reference16_filterIndexBufferMulti(unsigned short* destination, const unsigned short* indices, size_t index_count, size_t vertex_count, const struct meshopt_Stream* streams, size_t stream_count)
{
	return meshopt_filterIndexBufferMulti<unsigned short>(destination, indices, index_count, vertex_count, streams, stream_count);
}

extern "C" void reference16_generateShadowIndexBuffer(unsigned short* destination, const unsigned short* indices, size_t index_count, const void* vertices, size_t vertex_count, size_t vertex_size, size_t vertex_stride)
{
	meshopt_generateShadowIndexBuffer<unsigned short>(destination, indices, index_count, vertices, vertex_count, vertex_size, vertex_stride);
}

extern "C" void reference16_generateShadowIndexBufferMulti(unsigned short* destination, const unsigned short* indices, size_t index_count, size_t vertex_count, const meshopt_Stream* streams, size_t stream_count)
{
	meshopt_generateShadowIndexBufferMulti<unsigned short>(destination, indices, index_count, vertex_count, streams, stream_count);
}

extern "C" void reference16_generateAdjacencyIndexBuffer(unsigned short* destination, const unsigned short* indices, size_t index_count, const float* vertex_positions, size_t vertex_count, size_t vertex_positions_stride)
{
	meshopt_generateAdjacencyIndexBuffer<unsigned short>(destination, indices, index_count, vertex_positions, vertex_count, vertex_positions_stride);
}

extern "C" void reference16_generateTessellationIndexBuffer(unsigned short* destination, const unsigned short* indices, size_t index_count, const float* vertex_positions, size_t vertex_count, size_t vertex_positions_stride)
{
	meshopt_generateTessellationIndexBuffer<unsigned short>(destination, indices, index_count, vertex_positions, vertex_count, vertex_positions_stride);
}

extern "C" size_t reference16_generateProvokingIndexBuffer(unsigned short* destination, unsigned int* reorder, const unsigned short* indices, size_t index_count, size_t vertex_count)
{
	return meshopt_generateProvokingIndexBuffer<unsigned short>(destination, reorder, indices, index_count, vertex_count);
}

extern "C" void reference16_optimizeVertexCache(unsigned short* destination, const unsigned short* indices, size_t index_count, size_t vertex_count)
{
	meshopt_optimizeVertexCache<unsigned short>(destination, indices, index_count, vertex_count);
}

extern "C" void reference16_optimizeVertexCacheStrip(unsigned short* destination, const unsigned short* indices, size_t index_count, size_t vertex_count)
{
	meshopt_optimizeVertexCacheStrip<unsigned short>(destination, indices, index_count, vertex_count);
}

extern "C" void reference16_optimizeVertexCacheFifo(unsigned short* destination, const unsigned short* indices, size_t index_count, size_t vertex_count, unsigned int cache_size)
{
	meshopt_optimizeVertexCacheFifo<unsigned short>(destination, indices, index_count, vertex_count, cache_size);
}

extern "C" void reference16_optimizeOverdraw(unsigned short* destination, const unsigned short* indices, size_t index_count, const float* vertex_positions, size_t vertex_count, size_t vertex_positions_stride, float threshold)
{
	meshopt_optimizeOverdraw<unsigned short>(destination, indices, index_count, vertex_positions, vertex_count, vertex_positions_stride, threshold);
}

extern "C" size_t reference16_optimizeVertexFetchRemap(unsigned int* destination, const unsigned short* indices, size_t index_count, size_t vertex_count)
{
	return meshopt_optimizeVertexFetchRemap<unsigned short>(destination, indices, index_count, vertex_count);
}

extern "C" size_t reference16_optimizeVertexFetch(void* destination, unsigned short* indices, size_t index_count, const void* vertices, size_t vertex_count, size_t vertex_size)
{
	return meshopt_optimizeVertexFetch<unsigned short>(destination, indices, index_count, vertices, vertex_count, vertex_size);
}

extern "C" size_t reference16_encodeIndexBuffer(unsigned char* buffer, size_t buffer_size, const unsigned short* indices, size_t index_count)
{
	return meshopt_encodeIndexBuffer<unsigned short>(buffer, buffer_size, indices, index_count);
}

extern "C" int reference16_decodeIndexBuffer(unsigned short* destination, size_t index_count, const unsigned char* buffer, size_t buffer_size)
{
	return meshopt_decodeIndexBuffer<unsigned short>(destination, index_count, buffer, buffer_size);
}

extern "C" size_t reference16_encodeIndexSequence(unsigned char* buffer, size_t buffer_size, const unsigned short* indices, size_t index_count)
{
	return meshopt_encodeIndexSequence<unsigned short>(buffer, buffer_size, indices, index_count);
}

extern "C" int reference16_decodeIndexSequence(unsigned short* destination, size_t index_count, const unsigned char* buffer, size_t buffer_size)
{
	return meshopt_decodeIndexSequence<unsigned short>(destination, index_count, buffer, buffer_size);
}

extern "C" size_t reference16_simplify(unsigned short* destination, const unsigned short* indices, size_t index_count, const float* vertex_positions, size_t vertex_count, size_t vertex_positions_stride, size_t target_index_count, float target_error, unsigned int options, float* result_error)
{
	return meshopt_simplify<unsigned short>(destination, indices, index_count, vertex_positions, vertex_count, vertex_positions_stride, target_index_count, target_error, options, result_error);
}

extern "C" size_t reference16_simplifyWithAttributes(unsigned short* destination, const unsigned short* indices, size_t index_count, const float* vertex_positions, size_t vertex_count, size_t vertex_positions_stride, const float* vertex_attributes, size_t vertex_attributes_stride, const float* attribute_weights, size_t attribute_count, const unsigned char* vertex_lock, size_t target_index_count, float target_error, unsigned int options, float* result_error)
{
	return meshopt_simplifyWithAttributes<unsigned short>(destination, indices, index_count, vertex_positions, vertex_count, vertex_positions_stride, vertex_attributes, vertex_attributes_stride, attribute_weights, attribute_count, vertex_lock, target_index_count, target_error, options, result_error);
}

extern "C" size_t reference16_simplifyWithUpdate(unsigned short* indices, size_t index_count, float* vertex_positions, size_t vertex_count, size_t vertex_positions_stride, float* vertex_attributes, size_t vertex_attributes_stride, const float* attribute_weights, size_t attribute_count, const unsigned char* vertex_lock, size_t target_index_count, float target_error, unsigned int options, float* result_error)
{
	return meshopt_simplifyWithUpdate<unsigned short>(indices, index_count, vertex_positions, vertex_count, vertex_positions_stride, vertex_attributes, vertex_attributes_stride, attribute_weights, attribute_count, vertex_lock, target_index_count, target_error, options, result_error);
}

extern "C" size_t reference16_simplifySloppy(unsigned short* destination, const unsigned short* indices, size_t index_count, const float* vertex_positions, size_t vertex_count, size_t vertex_positions_stride, size_t target_index_count, float target_error, float* result_error)
{
	return meshopt_simplifySloppy<unsigned short>(destination, indices, index_count, vertex_positions, vertex_count, vertex_positions_stride, target_index_count, target_error, result_error);
}

extern "C" size_t reference16_simplifySloppyLocks(unsigned short* destination, const unsigned short* indices, size_t index_count, const float* vertex_positions, size_t vertex_count, size_t vertex_positions_stride, const unsigned char* vertex_lock, size_t target_index_count, float target_error, float* result_error)
{
	return meshopt_simplifySloppy<unsigned short>(destination, indices, index_count, vertex_positions, vertex_count, vertex_positions_stride, vertex_lock, target_index_count, target_error, result_error);
}

extern "C" size_t reference16_simplifyPrune(unsigned short* destination, const unsigned short* indices, size_t index_count, const float* vertex_positions, size_t vertex_count, size_t vertex_positions_stride, float target_error)
{
	return meshopt_simplifyPrune<unsigned short>(destination, indices, index_count, vertex_positions, vertex_count, vertex_positions_stride, target_error);
}

extern "C" size_t reference16_stripify(unsigned short* destination, const unsigned short* indices, size_t index_count, size_t vertex_count, unsigned short restart_index)
{
	return meshopt_stripify<unsigned short>(destination, indices, index_count, vertex_count, restart_index);
}

extern "C" size_t reference16_unstripify(unsigned short* destination, const unsigned short* indices, size_t index_count, unsigned short restart_index)
{
	return meshopt_unstripify<unsigned short>(destination, indices, index_count, restart_index);
}

extern "C" meshopt_VertexCacheStatistics reference16_analyzeVertexCache(const unsigned short* indices, size_t index_count, size_t vertex_count, unsigned int cache_size, unsigned int warp_size, unsigned int primgroup_size)
{
	return meshopt_analyzeVertexCache<unsigned short>(indices, index_count, vertex_count, cache_size, warp_size, primgroup_size);
}

extern "C" meshopt_VertexFetchStatistics reference16_analyzeVertexFetch(const unsigned short* indices, size_t index_count, size_t vertex_count, size_t vertex_size)
{
	return meshopt_analyzeVertexFetch<unsigned short>(indices, index_count, vertex_count, vertex_size);
}

extern "C" meshopt_OverdrawStatistics reference16_analyzeOverdraw(const unsigned short* indices, size_t index_count, const float* vertex_positions, size_t vertex_count, size_t vertex_positions_stride)
{
	return meshopt_analyzeOverdraw<unsigned short>(indices, index_count, vertex_positions, vertex_count, vertex_positions_stride);
}

extern "C" meshopt_CoverageStatistics reference16_analyzeCoverage(const unsigned short* indices, size_t index_count, const float* vertex_positions, size_t vertex_count, size_t vertex_positions_stride)
{
	return meshopt_analyzeCoverage<unsigned short>(indices, index_count, vertex_positions, vertex_count, vertex_positions_stride);
}

extern "C" size_t reference16_buildMeshlets(meshopt_Meshlet* meshlets, unsigned int* meshlet_vertices, unsigned char* meshlet_triangles, const unsigned short* indices, size_t index_count, const float* vertex_positions, size_t vertex_count, size_t vertex_positions_stride, size_t max_vertices, size_t max_triangles, float cone_weight)
{
	return meshopt_buildMeshlets<unsigned short>(meshlets, meshlet_vertices, meshlet_triangles, indices, index_count, vertex_positions, vertex_count, vertex_positions_stride, max_vertices, max_triangles, cone_weight);
}

extern "C" size_t reference16_buildMeshletsScan(meshopt_Meshlet* meshlets, unsigned int* meshlet_vertices, unsigned char* meshlet_triangles, const unsigned short* indices, size_t index_count, size_t vertex_count, size_t max_vertices, size_t max_triangles)
{
	return meshopt_buildMeshletsScan<unsigned short>(meshlets, meshlet_vertices, meshlet_triangles, indices, index_count, vertex_count, max_vertices, max_triangles);
}

extern "C" size_t reference16_buildMeshletsFlex(meshopt_Meshlet* meshlets, unsigned int* meshlet_vertices, unsigned char* meshlet_triangles, const unsigned short* indices, size_t index_count, const float* vertex_positions, size_t vertex_count, size_t vertex_positions_stride, size_t max_vertices, size_t min_triangles, size_t max_triangles, float cone_weight, float split_factor)
{
	return meshopt_buildMeshletsFlex<unsigned short>(meshlets, meshlet_vertices, meshlet_triangles, indices, index_count, vertex_positions, vertex_count, vertex_positions_stride, max_vertices, min_triangles, max_triangles, cone_weight, split_factor);
}

extern "C" size_t reference16_buildMeshletsSpatial(meshopt_Meshlet* meshlets, unsigned int* meshlet_vertices, unsigned char* meshlet_triangles, const unsigned short* indices, size_t index_count, const float* vertex_positions, size_t vertex_count, size_t vertex_positions_stride, size_t max_vertices, size_t min_triangles, size_t max_triangles, float fill_weight)
{
	return meshopt_buildMeshletsSpatial<unsigned short>(meshlets, meshlet_vertices, meshlet_triangles, indices, index_count, vertex_positions, vertex_count, vertex_positions_stride, max_vertices, min_triangles, max_triangles, fill_weight);
}

extern "C" meshopt_Bounds reference16_computeClusterBounds(const unsigned short* indices, size_t index_count, const float* vertex_positions, size_t vertex_count, size_t vertex_positions_stride)
{
	return meshopt_computeClusterBounds<unsigned short>(indices, index_count, vertex_positions, vertex_count, vertex_positions_stride);
}

extern "C" size_t reference16_partitionClusters(unsigned int* destination, const unsigned short* cluster_indices, size_t total_index_count, const unsigned int* cluster_index_counts, size_t cluster_count, const float* vertex_positions, size_t vertex_count, size_t vertex_positions_stride, size_t target_partition_size)
{
	return meshopt_partitionClusters<unsigned short>(destination, cluster_indices, total_index_count, cluster_index_counts, cluster_count, vertex_positions, vertex_count, vertex_positions_stride, target_partition_size);
}

extern "C" void reference16_spatialSortTriangles(unsigned short* destination, const unsigned short* indices, size_t index_count, const float* vertex_positions, size_t vertex_count, size_t vertex_positions_stride)
{
	meshopt_spatialSortTriangles<unsigned short>(destination, indices, index_count, vertex_positions, vertex_count, vertex_positions_stride);
}

extern "C" void reference16_generateTangents(float* result, const unsigned short* indices, size_t index_count, const float* vertex_positions, size_t vertex_count, size_t vertex_positions_stride, const float* vertex_normals, size_t vertex_normals_stride, const float* vertex_uvs, size_t vertex_uvs_stride, unsigned int options)
{
	meshopt_generateTangents<unsigned short>(result, indices, index_count, vertex_positions, vertex_count, vertex_positions_stride, vertex_normals, vertex_normals_stride, vertex_uvs, vertex_uvs_stride, options);
}

extern "C" void reference16_generateNormals(float* result, const unsigned short* indices, size_t index_count, const float* vertex_positions, size_t vertex_count, size_t vertex_positions_stride, float crease_angle, float smoothing)
{
	meshopt_generateNormals<unsigned short>(result, indices, index_count, vertex_positions, vertex_count, vertex_positions_stride, crease_angle, smoothing);
}

extern "C" size_t reference16_remesh(float* destination, size_t max_triangle_count, const unsigned short* indices, size_t index_count, const float* vertex_positions, size_t vertex_count, size_t vertex_positions_stride, int resolution, unsigned int options)
{
	return meshopt_remesh<unsigned short>(destination, max_triangle_count, indices, index_count, vertex_positions, vertex_count, vertex_positions_stride, resolution, options);
}
