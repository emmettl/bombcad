// Holds a benchmark's process open for BOMBCAD_PERF_LINGER seconds as it exits, so that
// Scripts/perf/run-standard.py can read its final GPU time from ioreg (AGXDeviceUserClient's
// accumulatedGPUTime goes with the process). Injected with DYLD_INSERT_LIBRARIES; changes nothing
// the benchmark computes or times.
#include <stdlib.h>
#include <unistd.h>

__attribute__((destructor)) static void linger(void) {
    const char *seconds = getenv("BOMBCAD_PERF_LINGER");
    if (seconds) usleep((useconds_t)(atof(seconds) * 1e6));
}
