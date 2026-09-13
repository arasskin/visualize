Pinned upstream: Expat 2.8.4.

Source archive: https://github.com/libexpat/libexpat/releases/download/R_2_8_4/expat-2.8.4.tar.gz

SHA-256: `b8ece2437692dad44d851c4532723390a5a330990007706be9c8d2b90d294f36`, verified against the release asset digest from GitHub's API.

This directory contains the unmodified release's `lib/*.[ch]`, `COPYING`, and `Changes`. Graphviz uses Expat to parse its HTML labels. The native bridge builds the parser with namespace and general-entity support, without DTD support, and uses `/dev/urandom` for entropy. Platform configuration lives in `src.graphviz/expat_config.h`.

`SHA256SUMS` records the imported files for checking local changes with `shasum -a 256 -c SHA256SUMS` from this directory.
