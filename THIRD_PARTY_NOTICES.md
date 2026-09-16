Visualize's original code is licensed under the root [MIT License](LICENSE), Copyright (c) 2026 arasskin. Third-party material retains its own copyright notices and license terms, including when modified for Visualize. The root MIT license does not replace those terms.

| Material | License and notices | Source |
| --- | --- | --- |
| Janet 1.41.2 | [MIT](external-src/janet/LICENSE), plus the public-domain SipHash attribution embedded in the amalgamation | [Janet](https://github.com/janet-lang/janet); shipped in `external-src/janet` |
| libvterm 0.3.3 | [MIT](src.vterm/LICENSE); [wcwidth notice](src.vterm/THIRD_PARTY_NOTICES.txt) | [libvterm](https://www.leonerd.org.uk/code/libvterm/); shipped in `src.vterm` |
| WTerm 0.5.0 DOM components | [Apache-2.0](src.wterm/LICENSE), Copyright 2025 Vercel, Inc.; modified files carry notices | [WTerm](https://github.com/vercel-labs/wterm); shipped in `src.wterm` |
| Graphviz 15.1.1 subset | [EPL-2.0](external-src/graphviz/COPYING); [additional BSD, Bison, and public-domain notices](external-src/graphviz/THIRD_PARTY_LICENSES.txt) | [Graphviz](https://graphviz.org/); shipped in `external-src/graphviz` |
| Expat 2.8.4 subset | [MIT](external-src/expat/COPYING); [CC0 for SipHash](external-src/expat/CC0-1.0.txt) | [Expat](https://github.com/libexpat/libexpat); shipped in `external-src/expat` |
| markdown-it 15.0.1 and bundled dependencies | [MIT and BSD-2-Clause notices](external-src/markdown-it/markdown-it.LICENSE.txt), also embedded in the browser bundle | [markdown-it](https://github.com/markdown-it/markdown-it); shipped in `external-src/markdown-it` |
| Parkinsans Regular, Medium, Bold | [SIL Open Font License 1.1](src/web/fonts/OFL.txt), Copyright 2024 The Parkinsans Project Authors | [Parkinsans](https://github.com/redstonedesign/parkinsans); shipped in `src/web/fonts` |

The Markdown bundle includes `mdurl`, `uc.micro`, `entities`, `linkify-it`, and `punycode.js`. Their complete notices are in the linked license file, including the Joyent/Node notice for the URL parser inside `mdurl`. `entities` uses BSD-2-Clause; the other listed JavaScript components use MIT.

The distributed Graphviz source, including the local patch described in [README.visualize.md](external-src/graphviz/README.visualize.md), is available under EPL-2.0 in `external-src/graphviz`. Visualize's native build configuration is in `src.graphviz`. The source is supplied with this repository at [arasskin/visualize](https://github.com/arasskin/visualize). The generated Graphviz parsers retain the Bison exception; their GPL skeleton notice does not license Visualize as a whole under GPL.

Local libvterm patches and their Neovim references are documented in [src.vterm/README.md](src.vterm/README.md). WTerm integration changes are described in [src.wterm/README.md](src.wterm/README.md). Original Visualize adapters and build scripts remain covered by the root MIT license; copied or modified upstream material retains the applicable upstream terms.

When redistributing a source checkout, retain these notices, the linked license files, and embedded source notices. A binary distribution must also carry the applicable notices and licenses, and state how to obtain the corresponding EPL-covered Graphviz source, including local modifications. Supply that source or identify an archive of the exact Visualize release or commit used to build the binary; a moving branch alone is not a reliable reference for the matching source.
