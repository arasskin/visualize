#include "bridge.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

static void *exercise(void *unused) {
    (void)unused;
    for (int i = 0; i < 100; ++i) {
        VzGraphvizResult *bad = vz_graphviz_render("digraph {a -> }");
        assert(bad && strstr(vz_graphviz_error(bad), "syntax error"));
        vz_graphviz_free(bad);
        VzGraphvizResult *good = vz_graphviz_render(
            "digraph {subgraph cluster_c {a [label=<hello<BR/>"
            "<FONT POINT-SIZE=\"8\">.cljd 42</FONT>>]; b;} a->b;}");
        assert(good && strstr(vz_graphviz_svg(good), ".cljd 42"));
        vz_graphviz_free(good);
    }
    return NULL;
}

int main(void) {
    pthread_t workers[4];
    for (int i = 0; i < 4; ++i)
        assert(pthread_create(&workers[i], NULL, exercise, NULL) == 0);
    for (int i = 0; i < 4; ++i)
        assert(pthread_join(workers[i], NULL) == 0);
    puts("400 valid and 400 invalid renders across four threads passed");
}
