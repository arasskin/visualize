#include "bridge.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
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

static void *wide_graph(void *unused) {
    (void)unused;
    const int nodes = 14000;
    const size_t capacity = (size_t)nodes * 96 + 128;
    char *dot = malloc(capacity);
    assert(dot);
    size_t used = (size_t)snprintf(dot, capacity,
        "digraph {node[label=\"\",fixedsize=true];\n");
    for (int i = 0; i < nodes; ++i) {
        int written = snprintf(dot + used, capacity - used,
            "n%d[width=%.1f];\n", i, (i % 17 + 1) / 2.0);
        assert(written > 0 && (size_t)written < capacity - used);
        used += (size_t)written;
        if (i) {
            written = snprintf(dot + used, capacity - used, "n0 -> n%d;\n", i);
            assert(written > 0 && (size_t)written < capacity - used);
            used += (size_t)written;
        }
    }
    assert(used + 2 < capacity);
    strcpy(dot + used, "}\n");
    VzGraphvizResult *result = vz_graphviz_render(dot);
    assert(result && !vz_graphviz_error(result)[0]);
    const char *svg = vz_graphviz_svg(result);
    int found = 0;
    for (const char *at = svg; (at = strstr(at, "class=\"node\"")); ++at) ++found;
    assert(found == nodes);
    found = 0;
    for (const char *at = svg; (at = strstr(at, "class=\"edge\"")); ++at) ++found;
    assert(found == nodes - 1);
    vz_graphviz_free(result);
    free(dot);
    return NULL;
}

int main(void) {
    pthread_t workers[4];
    for (int i = 0; i < 4; ++i)
        assert(pthread_create(&workers[i], NULL, exercise, NULL) == 0);
    for (int i = 0; i < 4; ++i)
        assert(pthread_join(workers[i], NULL) == 0);
    puts("400 valid and 400 invalid renders across four threads passed");
    pthread_attr_t attributes;
    assert(pthread_attr_init(&attributes) == 0);
    assert(pthread_attr_setstacksize(&attributes, 512 * 1024) == 0);
    pthread_t wide;
    assert(pthread_create(&wide, &attributes, wide_graph, NULL) == 0);
    assert(pthread_attr_destroy(&attributes) == 0);
    assert(pthread_join(wide, NULL) == 0);
    puts("14,000-node layout on a 512 KiB worker stack passed");
}
