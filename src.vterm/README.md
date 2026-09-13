# Visualize's libvterm

Pinned upstream libvterm 0.3.3, C99, MIT licensed. The source is kept here as requested; `src/` and `include/` retain upstream structure and copyright notices. `bridge.c` is Visualize's supervisor adapter.

Upstream archive: https://www.leonerd.org.uk/code/libvterm/libvterm-0.3.3.tar.gz

SHA-256: `09156f43dd2128bd347cbeebe50d9a571d32c64e0cf18d211197946aff7226e0`

Local changes to upstream:

- `src/state.c`: share the UTF-8 decoder state for split input, following Neovim commit `e40c5cb06d`.
- `src/screen.c`: preserve the cursor when an exact-width preceding line is resized, following Neovim commit `635acc7dc8`.
- `include/vterm.h`, `src/vterm_internal.h`, `src/vterm.c`, `src/state.c`: mode 2026 property, set/reset/query, and reset handling, following Neovim commit `b38173e493`. Publication gating belongs to the Janet supervisor, not libvterm's parser.

Neovim references: https://github.com/neovim/neovim/commit/e40c5cb06d, https://github.com/neovim/neovim/commit/635acc7dc8, https://github.com/neovim/neovim/commit/b38173e493.

`./build` at the repository root builds this alongside Janet. `./src.vterm/build --force` rebuilds only the native terminal library using the system C compiler. The resulting `libvisualize-vterm.so` is a dynamically loaded library on macOS and Linux; it includes libvterm itself and has no Homebrew libvterm dependency. Builds use a temporary file and atomic rename so existing supervisors keep their loaded library.

Emoji/grapheme changes, Kitty keyboard support, graphics protocols, and OSC 8 hyperlink metadata are not implemented here. Ordinary combining accents and double-width CJK cells are supported. See `docs/native-terminal.md` for the integration and protocol.
