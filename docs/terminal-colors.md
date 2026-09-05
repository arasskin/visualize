Terminal colors follow the macOS Terminal Clear Light and Clear Dark profiles, selected by the browser's `prefers-color-scheme` setting.

The palettes were copied from `/System/Applications/Utilities/Terminal.app/Contents/Resources/Initial Settings/` and converted from archived NSColor values to sRGB using AppKit. Backgrounds are opaque. The dark profile inherits the light profile's cursor color because it does not specify one.

`src/web/style.css` binds these colors to WTerm's foreground, background, cursor, and 16 ANSI variables. `src/web/term.js` also initializes the emulator with the matching foreground and background, and updates its colors on theme changes and wrapper resets. This makes OSC 10/11 color-query replies agree with the displayed terminal so applications can choose suitable input backgrounds.

An isolated Chrome check verified light and dark foreground/background replies, rendered ANSI red, theme switching, and background replies after wrapper resets. The bundled emulator did not answer an OSC 4 palette query; this check does not assert support for that query. The Codex input UI itself was not exercised.
