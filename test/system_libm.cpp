// The system libm's cosf and log2f, which the original calls, under C names
// for the tests of the port's versions. Built into the reference library,
// these bind to the system's libm as the original's calls do.
#include <math.h>

extern "C" float reference_cosf(float x)
{
	return cosf(x);
}

extern "C" float reference_log2f(float x)
{
	return log2f(x);
}
