License review, September 16, 2026.

No reviewed dependency license prevents licensing Visualize's original code under MIT. The root [LICENSE](../LICENSE) now applies MIT to that original code, and [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) records the separate terms for dependencies and fonts. This is a mixed-license distribution; not every file is MIT. The source-package notice fixes identified below have been applied. A binary release must preserve the same obligations in its packaging.

The review covered the vendored source directories, native build inputs, WTerm's JavaScript modules, the Markdown browser bundle, and the three bundled font files. Generated local binaries and the user's independently installed harnesses are outside the vendored-source inventory.

| Component | License found | Distribution requirements |
| --- | --- | --- |
| Janet 1.41.2 amalgamation, `external-src/janet` | MIT; embedded SipHash identified as public domain | Preserve the copyright and MIT text already embedded in the source. Carry notices into binary releases. |
| libvterm 0.3.3, `src.vterm` | MIT; `src/unicode.c` contains Markus Kuhn's permissive wcwidth notice | Preserve `LICENSE` and the embedded notice. Local changes and Neovim references are recorded in the README; Neovim's license inventory separately identifies libvterm as MIT. |
| WTerm 0.5.0 DOM components, `src.wterm` | Apache-2.0 | Preserve the Apache license and Vercel attribution. Modified upstream files must carry prominent modification notices. The published `@wterm/dom` package contains no separate NOTICE file. |
| Graphviz 15.1.1 subset, `external-src/graphviz` | EPL-2.0, with the embedded exceptions below | Keep Graphviz source and modifications under EPL. Preserve notices, include the license, and tell recipients where the corresponding source can be obtained, including for binary releases. |
| Expat 2.8.4 subset, `external-src/expat` | MIT; `lib/siphash.h` is CC0-1.0 | Preserve MIT notices and identify the separately licensed SipHash code. |
| markdown-it 15.0.1 browser bundle | MIT, plus bundled MIT and BSD-2-Clause dependencies | Preserve markdown-it's license and add the bundled dependencies' notices described below. |
| Parkinsans Regular, Medium, Bold | SIL Open Font License 1.1 | Ship the font copyright and full OFL text. The fonts remain OFL, not MIT. Bundling with the application is allowed. |

Graphviz requires special care, but not a different license for Visualize's independent code. EPL-2.0 section 1 excludes interface-only linking/binding material from its definition of Modified Works; section 3 requires the covered source and license to remain available. Visualize's bridge calls Graphviz through its API. The existing patch to `external-src/graphviz/lib/util/list.c` remains part of the EPL component. See the shipped [license](../external-src/graphviz/COPYING) and [patch description](../external-src/graphviz/README.visualize.md).

Graphviz also contains:

- Luc Maisonobe's BSD-3-Clause notice in `lib/common/ellipse.c`, retained in the source. Include it with a binary distribution as required by that notice.
- Generated Bison parsers in `lib/cgraph/grammar.{c,h}` and `lib/common/htmlparse.{c,h}`. Each contains the Bison 2.2 special exception, so the skeleton's GPL wording does not require Visualize as a whole to use GPL. Keep the exception and notices. [GNU's explanation](https://www.gnu.org/software/bison/manual/html_node/Conditions.html).
- Public-domain code identified in source comments, including MurmurHash in `lib/cgraph/refstr.c`.

Before adding notices, the local Markdown bundle was compared byte-for-byte with the documented published 15.0.1 browser bundle and matched. Its published source map identifies `mdurl`, `uc.micro`, `entities`, `linkify-it`, and `punycode.js` inside the shipped JavaScript. The package's command-line dependency `argparse` is not present in that source map. The corresponding upstream dependency license texts are MIT except `entities`, which is BSD-2-Clause. `mdurl/lib/parse.mjs` additionally carries a Joyent/Node MIT notice. These notices are now collected in `external-src/markdown-it/markdown-it.LICENSE.txt` and prepended to the browser bundle without changing its executable content. License texts were retrieved from entities 8.0.0, linkify-it 6.0.0, mdurl 2.1.0, punycode.js 2.3.1, and uc.micro 3.0.0, corresponding to the published dependency ranges. Exact resolved versions of every transitive dependency were not established from a build lockfile; retain a source/version inventory when refreshing the bundle.

The font metadata in all three TTFs identifies the Parkinsans authors and links to the OFL website, but does not embed the full license text. The matching upstream [Parkinsans OFL](https://raw.githubusercontent.com/google/fonts/main/ofl/parkinsans/OFL.txt) is now included at `src/web/fonts/OFL.txt`.

Completed source-package changes:

1. Added the root MIT license and explicit third-party boundaries in the README and notice inventory.
2. Added the Parkinsans OFL alongside the fonts.
3. Added the Markdown bundle's transitive notices, including the Node-derived URL parser.
4. Added file-level notices to all eight modified WTerm JavaScript/CSS files, as required by [Apache-2.0 section 4(b)](https://www.apache.org/licenses/LICENSE-2.0).
5. Added the root inventory and separate copies of Janet's MIT notice, libvterm's wcwidth notice, Expat's CC0 text, and Graphviz's embedded BSD/GPL-with-Bison-exception notices for packaging alongside binaries.

Source licensing is the same regardless of whether the build runs on macOS or Linux. A later binary release still needs its own packaging review so source-only notices are not accidentally omitted.
