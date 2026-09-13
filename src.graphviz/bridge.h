#pragma once
#define VZ_API __attribute__((visibility("default")))
typedef struct VzGraphvizResult VzGraphvizResult;
VZ_API VzGraphvizResult *vz_graphviz_render(const char *dot);
VZ_API const char *vz_graphviz_svg(VzGraphvizResult *result);
VZ_API const char *vz_graphviz_error(VzGraphvizResult *result);
VZ_API void vz_graphviz_free(VzGraphvizResult *result);
