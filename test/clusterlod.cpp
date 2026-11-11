// The original's cluster LOD builder, demo/clusterlod.h, built into the
// reference library for the oracle tests and the benchmark. Its functions
// take and return structs by value; these entry points pass them by pointer.
#include "meshoptimizer.h"

#define CLUSTERLOD_IMPLEMENTATION
#include "clusterlod.h"

typedef int (*reference_clodOutput)(void* context, const clodGroup* group, const clodCluster* clusters, size_t cluster_count);

struct ReferenceOutput
{
	void* context;
	reference_clodOutput output;
};

static int referenceOutput(void* context, clodGroup group, const clodCluster* clusters, size_t cluster_count)
{
	const ReferenceOutput* target = static_cast<const ReferenceOutput*>(context);
	return target->output(target->context, &group, clusters, cluster_count);
}

extern "C" void reference_clodDefaultConfig(clodConfig* config, size_t max_triangles)
{
	*config = clodDefaultConfig(max_triangles);
}

extern "C" void reference_clodDefaultConfigRT(clodConfig* config, size_t max_triangles)
{
	*config = clodDefaultConfigRT(max_triangles);
}

// Without an output, the original builds and hands nothing out.
extern "C" void reference_clodBuild(const clodConfig* config, const clodMesh* mesh, void* context, reference_clodOutput output)
{
	ReferenceOutput target = {context, output};
	clodBuild(*config, *mesh, &target, output ? referenceOutput : NULL);
}

// The sizes of the structs, for the tests to check their Zig declarations.
extern "C" void reference_clodSizes(size_t* sizes)
{
	sizes[0] = sizeof(clodConfig);
	sizes[1] = sizeof(clodMesh);
	sizes[2] = sizeof(clodBounds);
	sizes[3] = sizeof(clodCluster);
	sizes[4] = sizeof(clodGroup);
	sizes[5] = sizeof(clodNode);
}
