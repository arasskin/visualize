Indented dependencies in a `.visualize` file can refer to exact paths from the visualized project's root:

```text
verification
    a.txt
    dir/a.txt
```

`a.txt` matches the top-level file. `dir/a.txt` matches that file inside `dir`. Paths remain relative to the project even when the `.visualize` file is in a subdirectory. Matching is case sensitive and includes the extension. A dotted filename such as `dir.a.txt` is a literal filename, not an alternative spelling of `dir/a.txt`.

An explicitly declared heading in the same `.visualize` file takes precedence, regardless of declaration order. Otherwise, a matching file node replaces the implicit local dependency node. If there is no matching file node, the existing local-node behavior remains. There is no search beside the `.visualize` file, by basename, by suffix, or elsewhere in the project. Files that describe a graph without having their own file node do not become file targets through this mechanism.

The resulting dependency points to the existing file node, retaining its file mapping, size, grouping, and folding behavior. If a referenced file disappears, the next scan restores the implicit local node.
