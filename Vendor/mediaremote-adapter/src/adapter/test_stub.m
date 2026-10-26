// Halo: stands in for upstream's test.m, which needs a separate test client
// (src/test) that Halo doesn't ship. Halo never runs the "test" command, so
// this only keeps the exported symbol the Perl script knows about.

#include <stdio.h>
#include <stdlib.h>

#import "MediaRemoteAdapter.h"

extern void adapter_test(void) {
    fprintf(stderr, "The test command isn't included in Halo's build.\n");
    exit(1);
}
