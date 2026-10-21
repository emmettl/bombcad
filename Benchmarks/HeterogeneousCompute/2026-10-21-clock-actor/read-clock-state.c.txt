/* Read Linux clock discipline; modes=0 makes adjtimex a query, never an update. */
#include <errno.h>
#include <stdio.h>
#include <sys/timex.h>

int main(void) {
    struct timex state = {0};
    int result = adjtimex(&state);
    if (result == -1) {
        perror("adjtimex read");
        return 1;
    }
    printf("{\"queryModes\":0,\"returnState\":%d,\"status\":%d,"
           "\"tickMicroseconds\":%ld,\"frequencyScaledPPM\":%ld,"
           "\"frequencyPPM\":%.9f,\"offset\":%ld,\"timeConstant\":%ld,"
           "\"precision\":%ld,\"toleranceScaledPPM\":%ld}\n",
           result, state.status, state.tick, state.freq,
           state.freq / 65536.0, state.offset, state.constant,
           state.precision, state.tolerance);
    return 0;
}
