#include "bridge.h"
#include <cgraph/cgraph.h>
#include <gvc/gvc.h>
#include <gvc/gvplugin.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

extern gvplugin_library_t gvplugin_dot_layout_LTX_library;
extern gvplugin_installed_t gvdevice_svg_types[];
extern gvplugin_installed_t gvrender_svg_types[];

static gvplugin_api_t svg_apis[] = {
    {API_device, gvdevice_svg_types},
    {API_render, gvrender_svg_types},
    {0, NULL},
};
static gvplugin_library_t svg_library = {"core", svg_apis};
static const lt_symlist_t plugins[] = {
    {"gvplugin_dot_layout_LTX_library", &gvplugin_dot_layout_LTX_library},
    {"gvplugin_core_LTX_library", &svg_library},
    {NULL, NULL},
};
static pthread_mutex_t graphviz_lock = PTHREAD_MUTEX_INITIALIZER;

struct VzGraphvizResult {
    char *svg;
    char error[8192];
};

static VzGraphvizResult *active_result;

static int capture_error(char *message) {
    if (active_result) {
        size_t used = strlen(active_result->error);
        size_t available = sizeof(active_result->error) - used - 1;
        size_t length = strlen(message);
        if (length > available) length = available;
        memcpy(active_result->error + used, message, length);
        active_result->error[used + length] = '\0';
    }
    return 0;
}

VZ_API VzGraphvizResult *vz_graphviz_render(const char *dot) {
    VzGraphvizResult *result = calloc(1, sizeof(*result));
    if (!result) return NULL;
    pthread_mutex_lock(&graphviz_lock);
    active_result = result;
    agusererrf previous_error = agseterrf(capture_error);
    agreseterrors();
    GVC_t *context = gvContextPlugins(plugins, 0);
    Agraph_t *graph = dot ? agmemread(dot) : NULL;
    if (context && graph) {
        if (gvLayout(context, graph, "dot") == 0) {
            char *svg = NULL;
            size_t length = 0;
            if (gvRenderData(context, graph, "svg", &svg, &length) == 0 && svg) {
                result->svg = malloc(length + 1);
                if (result->svg) {
                    memcpy(result->svg, svg, length);
                    result->svg[length] = '\0';
                }
            }
            if (svg) gvFreeRenderData(svg);
        }
        gvFreeLayout(context, graph);
    }
    if (graph) agclose(graph);
    if (context) gvFreeContext(context);
    agseterrf(previous_error);
    active_result = NULL;
    pthread_mutex_unlock(&graphviz_lock);
    if (!result->svg && !result->error[0])
        strcpy(result->error, "Graphviz could not render the graph");
    return result;
}

VZ_API const char *vz_graphviz_svg(VzGraphvizResult *result) { return result->svg ? result->svg : ""; }
VZ_API const char *vz_graphviz_error(VzGraphvizResult *result) { return result->error; }
VZ_API void vz_graphviz_free(VzGraphvizResult *result) {
    if (!result) return;
    free(result->svg);
    free(result);
}
