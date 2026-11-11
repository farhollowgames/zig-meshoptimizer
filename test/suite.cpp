// meshoptimizer's own tests, demo/tests.cpp of the pinned upstream included
// unmodified, each as a C function test/suite.zig calls. They run against
// the port through test/capi.zig.
#include "tests.cpp"

// The allocator hooks of the original's allocator.cpp, which the port's
// scratch memory goes through in this suite.
extern "C" void* suite_allocate(size_t size)
{
	return meshopt_Allocator::storage().allocate(size);
}

extern "C" void suite_deallocate(void* ptr)
{
	meshopt_Allocator::storage().deallocate(ptr);
}

extern "C" void suite_decodeIndexV0()
{
	decodeIndexV0();
}

extern "C" void suite_decodeIndexV1()
{
	decodeIndexV1();
}

extern "C" void suite_decodeIndexV1More()
{
	decodeIndexV1More();
}

extern "C" void suite_decodeIndexV1ThreeEdges()
{
	decodeIndexV1ThreeEdges();
}

extern "C" void suite_decodeIndex16()
{
	decodeIndex16();
}

extern "C" void suite_encodeIndexMemorySafe()
{
	encodeIndexMemorySafe();
}

extern "C" void suite_decodeIndexMemorySafe()
{
	decodeIndexMemorySafe();
}

extern "C" void suite_decodeIndexRejectExtraBytes()
{
	decodeIndexRejectExtraBytes();
}

extern "C" void suite_decodeIndexRejectMalformedHeaders()
{
	decodeIndexRejectMalformedHeaders();
}

extern "C" void suite_decodeIndexRejectInvalidVersion()
{
	decodeIndexRejectInvalidVersion();
}

extern "C" void suite_decodeIndexMalformedVByte()
{
	decodeIndexMalformedVByte();
}

extern "C" void suite_roundtripIndexTricky()
{
	roundtripIndexTricky();
}

extern "C" void suite_encodeIndexEmpty()
{
	encodeIndexEmpty();
}

extern "C" void suite_decodeIndexSequence()
{
	decodeIndexSequence();
}

extern "C" void suite_decodeIndexSequence16()
{
	decodeIndexSequence16();
}

extern "C" void suite_encodeIndexSequenceMemorySafe()
{
	encodeIndexSequenceMemorySafe();
}

extern "C" void suite_decodeIndexSequenceMemorySafe()
{
	decodeIndexSequenceMemorySafe();
}

extern "C" void suite_decodeIndexSequenceRejectExtraBytes()
{
	decodeIndexSequenceRejectExtraBytes();
}

extern "C" void suite_decodeIndexSequenceRejectMalformedHeaders()
{
	decodeIndexSequenceRejectMalformedHeaders();
}

extern "C" void suite_decodeIndexSequenceRejectInvalidVersion()
{
	decodeIndexSequenceRejectInvalidVersion();
}

extern "C" void suite_encodeIndexSequenceEmpty()
{
	encodeIndexSequenceEmpty();
}

extern "C" void suite_decodeVertexV0()
{
	decodeVertexV0();
}

extern "C" void suite_decodeVertexV0More()
{
	decodeVertexV0More();
}

extern "C" void suite_decodeVertexV0Mode2()
{
	decodeVertexV0Mode2();
}

extern "C" void suite_decodeVertexV1()
{
	decodeVertexV1();
}

extern "C" void suite_decodeVertexV1Custom()
{
	decodeVertexV1Custom();
}

extern "C" void suite_decodeVertexV1Deltas()
{
	decodeVertexV1Deltas();
}

extern "C" void suite_decodeVertexMemorySafe(int version)
{
	meshopt_encodeVertexVersion(version);
	decodeVertexMemorySafe();
	meshopt_encodeVertexVersion(1);
}

extern "C" void suite_decodeVertexRejectExtraBytes(int version)
{
	meshopt_encodeVertexVersion(version);
	decodeVertexRejectExtraBytes();
	meshopt_encodeVertexVersion(1);
}

extern "C" void suite_decodeVertexRejectMalformedHeaders(int version)
{
	meshopt_encodeVertexVersion(version);
	decodeVertexRejectMalformedHeaders();
	meshopt_encodeVertexVersion(1);
}

extern "C" void suite_decodeVertexBitGroups(int version)
{
	meshopt_encodeVertexVersion(version);
	decodeVertexBitGroups();
	meshopt_encodeVertexVersion(1);
}

extern "C" void suite_decodeVertexBitGroupSentinels(int version)
{
	meshopt_encodeVertexVersion(version);
	decodeVertexBitGroupSentinels();
	meshopt_encodeVertexVersion(1);
}

extern "C" void suite_decodeVertexBitGroupSentinelCount(int version)
{
	meshopt_encodeVertexVersion(version);
	decodeVertexBitGroupSentinelCount();
	meshopt_encodeVertexVersion(1);
}

extern "C" void suite_decodeVertexDeltas(int version)
{
	meshopt_encodeVertexVersion(version);
	decodeVertexDeltas();
	meshopt_encodeVertexVersion(1);
}

extern "C" void suite_decodeVertexBitXor(int version)
{
	meshopt_encodeVertexVersion(version);
	decodeVertexBitXor();
	meshopt_encodeVertexVersion(1);
}

extern "C" void suite_decodeVertexLarge(int version)
{
	meshopt_encodeVertexVersion(version);
	decodeVertexLarge();
	meshopt_encodeVertexVersion(1);
}

extern "C" void suite_decodeVertexSmall(int version)
{
	meshopt_encodeVertexVersion(version);
	decodeVertexSmall();
	meshopt_encodeVertexVersion(1);
}

extern "C" void suite_encodeVertexEmpty(int version)
{
	meshopt_encodeVertexVersion(version);
	encodeVertexEmpty();
	meshopt_encodeVertexVersion(1);
}

extern "C" void suite_encodeVertexMemorySafe(int version)
{
	meshopt_encodeVertexVersion(version);
	encodeVertexMemorySafe();
	meshopt_encodeVertexVersion(1);
}

extern "C" void suite_decodeVersion()
{
	decodeVersion();
}

extern "C" void suite_decodeFilterOct8()
{
	decodeFilterOct8();
}

extern "C" void suite_decodeFilterOct12()
{
	decodeFilterOct12();
}

extern "C" void suite_decodeFilterQuat12()
{
	decodeFilterQuat12();
}

extern "C" void suite_decodeFilterExp()
{
	decodeFilterExp();
}

extern "C" void suite_encodeFilterOct8()
{
	encodeFilterOct8();
}

extern "C" void suite_encodeFilterOct12()
{
	encodeFilterOct12();
}

extern "C" void suite_encodeFilterQuat12()
{
	encodeFilterQuat12();
}

extern "C" void suite_encodeFilterExp()
{
	encodeFilterExp();
}

extern "C" void suite_encodeFilterExpZero()
{
	encodeFilterExpZero();
}

extern "C" void suite_encodeFilterExpOverflow()
{
	encodeFilterExpOverflow();
}

extern "C" void suite_encodeFilterExpZeroShared()
{
	encodeFilterExpZeroShared();
}

extern "C" void suite_encodeFilterExpAlias()
{
	encodeFilterExpAlias();
}

extern "C" void suite_encodeFilterExpClamp()
{
	encodeFilterExpClamp();
}

extern "C" void suite_encodeFilterColor8()
{
	encodeFilterColor8();
}

extern "C" void suite_encodeFilterColor12()
{
	encodeFilterColor12();
}

extern "C" void suite_clusterBoundsDegenerate()
{
	clusterBoundsDegenerate();
}

extern "C" void suite_sphereBounds()
{
	sphereBounds();
}

extern "C" void suite_extractMeshlet()
{
	extractMeshlet();
}

extern "C" void suite_meshletsEmpty()
{
	meshletsEmpty();
}

extern "C" void suite_meshletsDense()
{
	meshletsDense();
}

extern "C" void suite_meshletsSparse()
{
	meshletsSparse();
}

extern "C" void suite_meshletsFlex()
{
	meshletsFlex();
}

extern "C" void suite_meshletsMax()
{
	meshletsMax();
}

extern "C" void suite_meshletsSpatial()
{
	meshletsSpatial();
}

extern "C" void suite_meshletsSpatialDeep()
{
	meshletsSpatialDeep();
}

extern "C" void suite_partitionBasic()
{
	partitionBasic();
}

extern "C" void suite_partitionSpatial()
{
	partitionSpatial();
}

extern "C" void suite_partitionSpatialMerge()
{
	partitionSpatialMerge();
}

extern "C" void suite_remapCustom()
{
	remapCustom();
}

extern "C" void suite_customAllocator()
{
	customAllocator();
}

extern "C" void suite_customAllocatorCache()
{
	customAllocatorCache();
}

extern "C" void suite_emptyMesh()
{
	emptyMesh();
}

extern "C" void suite_simplify()
{
	simplify();
}

extern "C" void suite_simplifyStuck()
{
	simplifyStuck();
}

extern "C" void suite_simplifySloppyStuck()
{
	simplifySloppyStuck();
}

extern "C" void suite_simplifySloppyLocks()
{
	simplifySloppyLocks();
}

extern "C" void suite_simplifyPointsStuck()
{
	simplifyPointsStuck();
}

extern "C" void suite_simplifyFlip()
{
	simplifyFlip();
}

extern "C" void suite_simplifyScale()
{
	simplifyScale();
}

extern "C" void suite_simplifyDegenerate()
{
	simplifyDegenerate();
}

extern "C" void suite_simplifyLockBorder()
{
	simplifyLockBorder();
}

extern "C" void suite_simplifyAttr(int arg)
{
	simplifyAttr(arg != 0);
}

extern "C" void suite_simplifyLockFlags()
{
	simplifyLockFlags();
}

extern "C" void suite_simplifyLockFlagsSeam()
{
	simplifyLockFlagsSeam();
}

extern "C" void suite_simplifySparse()
{
	simplifySparse();
}

extern "C" void suite_simplifyErrorAbsolute()
{
	simplifyErrorAbsolute();
}

extern "C" void suite_simplifySeam()
{
	simplifySeam();
}

extern "C" void suite_simplifySeamFake()
{
	simplifySeamFake();
}

extern "C" void suite_simplifySeamAttr()
{
	simplifySeamAttr();
}

extern "C" void suite_simplifyDebug()
{
	simplifyDebug();
}

extern "C" void suite_simplifyPrune()
{
	simplifyPrune();
}

extern "C" void suite_simplifyPruneCleanup()
{
	simplifyPruneCleanup();
}

extern "C" void suite_simplifyPruneFunc()
{
	simplifyPruneFunc();
}

extern "C" void suite_simplifyUpdate()
{
	simplifyUpdate();
}

extern "C" void suite_simplifyUpdateLocked(unsigned int arg)
{
	simplifyUpdateLocked(arg);
}

extern "C" void suite_simplifyFolds()
{
	simplifyFolds();
}

extern "C" void suite_filterTriangles()
{
	filterTriangles();
}

extern "C" void suite_adjacency()
{
	adjacency();
}

extern "C" void suite_tessellation()
{
	tessellation();
}

extern "C" void suite_provoking()
{
	provoking();
}

extern "C" void suite_quantizeFloat()
{
	quantizeFloat();
}

extern "C" void suite_quantizeHalf()
{
	quantizeHalf();
}

extern "C" void suite_dequantizeHalf()
{
	dequantizeHalf();
}

extern "C" void suite_computePositionExponent()
{
	computePositionExponent();
}

extern "C" void suite_encodeMeshletBound()
{
	encodeMeshletBound();
}

extern "C" void suite_decodeMeshletSafety()
{
	decodeMeshletSafety();
}

extern "C" void suite_decodeMeshletBasic()
{
	decodeMeshletBasic();
}

extern "C" void suite_decodeMeshletTypical()
{
	decodeMeshletTypical();
}

extern "C" void suite_opacityMap()
{
	opacityMap();
}

extern "C" void suite_opacityMapRasterize0()
{
	opacityMapRasterize0();
}

extern "C" void suite_opacityMapSpecial()
{
	opacityMapSpecial();
}

extern "C" void suite_tangentsBasic()
{
	tangentsBasic();
}

extern "C" void suite_tangentDegenerate()
{
	tangentDegenerate();
}

extern "C" void suite_normalsBasic()
{
	normalsBasic();
}

extern "C" void suite_normalsDegenerate()
{
	normalsDegenerate();
}
