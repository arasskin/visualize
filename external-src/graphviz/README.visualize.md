Pinned upstream: Graphviz 15.1.1.

Source archive: https://gitlab.com/api/v4/projects/4207231/packages/generic/graphviz-releases/15.1.1/graphviz-15.1.1.tar.gz

SHA-256: `d511d8938bbfe985b84506c96d1bbf1acba4ad88e62b51421a8b954e572f30d9`, verified against the accompanying upstream `.sha256` file.

This directory contains C sources, headers, parser grammars, and source lists from `lib/{cdt,cgraph,common,dotgen,gvc,label,pack,pathplan,util,xdot}`, the FDP headers referenced by shared code, the two `plugin/dot_layout` sources, and `plugin/core/gvrender_core_svg.c`. The release's generated parsers, entity table, and color table are included, so building does not require Bison, Flex, or Python. `COPYING`, `AUTHORS`, `graphviz_version.h`, and `builddate.h` also come from that archive.

Visualize's build configuration and plugin registration live separately in `src.graphviz`. One correctness patch in `lib/util/list.c` makes its four slot helpers return NULL directly for an empty backing store instead of adding zero to a null pointer. UBSan detected this during the repeated-render test. Other upstream sources are unchanged.

See `src.graphviz/README.md` for the supported subset and update considerations. `SHA256SUMS` records the shipped files, including that patch, for checking local changes with `shasum -a 256 -c SHA256SUMS` from this directory.
