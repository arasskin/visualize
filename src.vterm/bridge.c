#include "src/vterm_internal.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define HISTORY 2000
#define REPLIES 65536
#define HISTORY_BYTES (8u * 1024u * 1024u)

typedef struct { int cols; VTermScreenCell *cells; unsigned revision; } Line;
typedef struct {
  VTerm *vt;
  VTermScreen *screen;
  int rows, cols, visible, alternate, unknown_csi, unknown_osc, failures;
  unsigned char *dirty;
  Line history[HISTORY];
  int head, count, discarded;
  size_t history_bytes;
  unsigned revision, sync_generation;
  unsigned *row_revision;
  char title[4096];
  size_t title_len;
  char osc[128];
  size_t osc_len;
  int cell_width, cell_height;
  char replies[REPLIES];
  size_t reply_len;
} Terminal;

static int damage(VTermRect rect, void *user) {
  Terminal *t = user;
  for (int row = rect.start_row; row < rect.end_row && row < t->rows; row++)
    if (row >= 0) { t->dirty[row] = 1; t->row_revision[row] = t->revision; }
  return 1;
}
static int cursor(VTermPos pos, VTermPos old, int visible, void *user) {
  (void)pos; (void)old;
  ((Terminal *)user)->visible = visible;
  return 1;
}
static int property(VTermProp prop, VTermValue *value, void *user) {
  Terminal *t = user;
  if (prop == VTERM_PROP_CURSORVISIBLE) t->visible = value->boolean;
  if (prop == VTERM_PROP_ALTSCREEN) t->alternate = value->boolean;
  if (prop == VTERM_PROP_SYNCOUTPUT && value->boolean && !vterm_obtain_state(t->vt)->mode.synchronized_output) t->sync_generation++;
  if (prop == VTERM_PROP_TITLE) {
    VTermStringFragment fragment = value->string;
    if (fragment.initial) t->title_len = 0;
    size_t len = fragment.len;
    if (len > sizeof(t->title) - 1 - t->title_len) len = sizeof(t->title) - 1 - t->title_len;
    memcpy(t->title + t->title_len, fragment.str, len);
    t->title_len += len;
    t->title[t->title_len] = 0;
  }
  return 1;
}
static int clear_history(void *user) {
  Terminal *t = user;
  for (int i = 0; i < HISTORY; i++) {
    free(t->history[i].cells);
    t->history[i] = (Line){0};
  }
  t->discarded += t->count;
  t->head = t->count = 0; t->history_bytes = 0;
  return 1;
}
static int push(int cols, const VTermScreenCell *cells, void *user) {
  Terminal *t = user;
  VTermScreenCell *copy = malloc((size_t)cols * sizeof(*copy));
  if (!copy) { t->failures++; return 0; }
  memcpy(copy, cells, (size_t)cols * sizeof(*copy));
  while (t->count && (t->count == HISTORY || t->history_bytes + (size_t)cols * sizeof(*copy) > HISTORY_BYTES)) {
    t->history_bytes -= (size_t)t->history[t->head].cols * sizeof(*copy);
    free(t->history[t->head].cells);
    t->history[t->head] = (Line){0};
    t->head = (t->head + 1) % HISTORY;
    t->count--; t->discarded++;
  }
  t->history[(t->head + t->count++) % HISTORY] = (Line){cols, copy, t->revision};
  t->history_bytes += (size_t)cols * sizeof(*copy);
  return 1;
}
static int pop(int cols, VTermScreenCell *cells, void *user) {
  Terminal *t = user;
  if (!t->count) return 0;
  Line *line = &t->history[(t->head + --t->count) % HISTORY];
  VTermColor fg, bg;
  vterm_state_get_default_colors(vterm_obtain_state(t->vt), &fg, &bg);
  for (int i = 0; i < cols; i++)
    cells[i] = (VTermScreenCell){.width = 1, .fg = fg, .bg = bg};
  memcpy(cells, line->cells, (size_t)(cols < line->cols ? cols : line->cols) * sizeof(*cells));
  t->history_bytes -= (size_t)line->cols * sizeof(*cells);
  free(line->cells); *line = (Line){0};
  return 1;
}
static void reply(const char *bytes, size_t len, void *user) {
  Terminal *t = user;
  if (len > REPLIES - t->reply_len) { t->failures++; return; }
  memcpy(t->replies + t->reply_len, bytes, len);
  t->reply_len += len;
}
static int unknown_csi(const char *leader, const long args[], int argc,
                       const char *intermed, char command, void *user) {
  (void)leader; (void)args; (void)argc; (void)intermed; (void)command;
  Terminal *t = user;
  if ((!leader || !leader[0]) && (!intermed || !intermed[0]) && command == 't' && argc == 1) {
    char response[80]; int len = 0;
    if (args[0] == 18) len = snprintf(response, sizeof(response), "\033[8;%d;%dt", t->rows, t->cols);
    if (args[0] == 14) len = snprintf(response, sizeof(response), "\033[4;%d;%dt", t->rows * t->cell_height, t->cols * t->cell_width);
    if (args[0] == 16) len = snprintf(response, sizeof(response), "\033[6;%d;%dt", t->cell_height, t->cell_width);
    if (len > 0) { reply(response, (size_t)len, t); return 1; }
  }
  t->unknown_csi++;
  return 1;
}
static int unknown_osc(int command, VTermStringFragment frag, void *user) {
  Terminal *t = user;
  if (frag.initial) t->osc_len = 0;
  if (t->osc_len + frag.len >= sizeof(t->osc)) { t->osc_len = sizeof(t->osc); return 1; }
  memcpy(t->osc + t->osc_len, frag.str, frag.len);
  t->osc_len += frag.len; t->osc[t->osc_len] = 0;
  if (!frag.final) return 1;
  VTermState *state = vterm_obtain_state(t->vt);
  VTermColor fg, bg, c;
  vterm_state_get_default_colors(state, &fg, &bg);
  char response[100]; int len = 0;
  if ((command == 10 || command == 11) && !strcmp(t->osc, "?")) {
    c = command == 10 ? fg : bg;
    vterm_state_convert_color_to_rgb(state, &c);
    len = snprintf(response, sizeof(response), "\033]%d;rgb:%04x/%04x/%04x\033\\", command, c.rgb.red * 257, c.rgb.green * 257, c.rgb.blue * 257);
  } else if (command == 4) {
    int index, consumed = 0;
    if (sscanf(t->osc, "%d;?%n", &index, &consumed) == 1 && consumed && !t->osc[consumed] && index >= 0 && index < 256) {
      vterm_state_get_palette_color(state, index, &c);
      vterm_state_convert_color_to_rgb(state, &c);
      len = snprintf(response, sizeof(response), "\033]4;%d;rgb:%04x/%04x/%04x\033\\", index, c.rgb.red * 257, c.rgb.green * 257, c.rgb.blue * 257);
    }
  }
  if (len > 0) reply(response, (size_t)len, t);
  else t->unknown_osc++;
  return 1;
}
static const VTermScreenCallbacks callbacks = {
  .damage = damage, .movecursor = cursor, .settermprop = property,
  .sb_pushline = push, .sb_popline = pop, .sb_clear = clear_history
};
static const VTermStateFallbacks fallbacks = {.csi = unknown_csi, .osc = unknown_osc};

void *vz_new(int rows, int cols) {
  if (rows < 1 || cols < 1 || rows > 1000 || cols > 1000) return NULL;
  Terminal *t = calloc(1, sizeof(*t));
  if (!t) return NULL;
  t->rows = rows; t->cols = cols; t->visible = 1; t->cell_width = 8; t->cell_height = 17;
  t->revision = 1;
  t->row_revision = calloc((size_t)rows, sizeof(unsigned));
  t->dirty = calloc((size_t)rows, 1);
  t->vt = vterm_new(rows, cols);
  if (!t->dirty || !t->row_revision || !t->vt) {
    if (t->vt) vterm_free(t->vt);
    free(t->row_revision); free(t->dirty); free(t); return NULL;
  }
  vterm_set_utf8(t->vt, 1);
  vterm_output_set_callback(t->vt, reply, t);
  t->screen = vterm_obtain_screen(t->vt);
  vterm_screen_set_callbacks(t->screen, &callbacks, t);
  vterm_screen_set_unrecognised_fallbacks(t->screen, &fallbacks, t);
  vterm_screen_enable_altscreen(t->screen, 1);
  vterm_screen_enable_reflow(t->screen, 1);
  vterm_screen_set_damage_merge(t->screen, VTERM_DAMAGE_ROW);
  vterm_screen_reset(t->screen, 1);
  vterm_screen_flush_damage(t->screen);
  return t;
}
void vz_free(Terminal *t) {
  if (!t) return;
  vterm_free(t->vt); clear_history(t); free(t->row_revision); free(t->dirty); free(t);
}
size_t vz_write(Terminal *t, const char *bytes, size_t len) {
  t->revision++;
  size_t consumed = vterm_input_write(t->vt, bytes, len);
  vterm_screen_flush_damage(t->screen);
  return consumed;
}
int vz_resize(Terminal *t, int rows, int cols) {
  if (rows < 1 || cols < 1 || rows > 1000 || cols > 1000) return 0;
  unsigned char *dirty = calloc((size_t)rows, 1);
  unsigned *versions = calloc((size_t)rows, sizeof(unsigned));
  if (!dirty || !versions) { free(dirty); free(versions); return 0; }
  t->revision++;
  for (int r = 0; r < rows; r++) versions[r] = t->revision;
  free(t->row_revision); t->row_revision = versions;
  free(t->dirty); t->dirty = dirty; t->rows = rows; t->cols = cols;
  vterm_set_size(t->vt, rows, cols);
  vterm_screen_flush_damage(t->screen);
  memset(t->dirty, 1, (size_t)rows);
  return 1;
}
size_t vz_text(Terminal *t, char *out, size_t size) {
  return vterm_screen_get_text(t->screen, out, size, (VTermRect){0,t->rows,0,t->cols});
}
size_t vz_replies(Terminal *t, char *out, size_t size) {
  size_t len = t->reply_len < size ? t->reply_len : size;
  memcpy(out, t->replies, len);
  memmove(t->replies, t->replies + len, t->reply_len - len);
  t->reply_len -= len;
  return len;
}
int vz_info(Terminal *t, int key) {
  VTermPos pos;
  vterm_state_get_cursorpos(vterm_obtain_state(t->vt), &pos);
  VTermState *state = vterm_obtain_state(t->vt);
  switch(key) {
    case 0: return t->rows; case 1: return t->cols;
    case 2: return pos.row; case 3: return pos.col;
    case 4: return t->visible; case 5: return t->alternate;
    case 6: return t->count; case 7: return t->unknown_csi;
    case 8: return t->unknown_osc; case 9: return t->failures;
    case 10: return (int)t->revision;
    case 11: return state->mode.synchronized_output;
    case 12: return (int)t->sync_generation;
    case 13: return t->discarded;
    case 14: return state->mode.cursor;
    case 15: return state->mode.bracketpaste;
    case 16: return (state->mouse_flags & MOUSE_WANT_MOVE) ? 3 : (state->mouse_flags & MOUSE_WANT_DRAG) ? 2 : (state->mouse_flags & MOUSE_WANT_CLICK) ? 1 : 0;
    case 17: return state->mouse_protocol == MOUSE_SGR;
    case 18: return state->mode.report_focus;
  }
  return -1;
}
int vz_dirty(Terminal *t, int row) {
  return row >= 0 && row < t->rows ? t->dirty[row] : 0;
}
void vz_clean(Terminal *t) { memset(t->dirty, 0, (size_t)t->rows); }
int vz_cell(Terminal *t, int history, int row, int col, uint32_t out[11]) {
  VTermScreenCell cell = {0};
  if (history) {
    if (row < 0 || row >= t->count) return 0;
    Line *line = &t->history[(t->head + row) % HISTORY];
    if (col < 0 || col >= line->cols) return 0;
    cell = line->cells[col];
  } else {
    if (row < 0 || row >= t->rows || col < 0 || col >= t->cols) return 0;
    if (!vterm_screen_get_cell(t->screen, (VTermPos){row,col}, &cell)) return 0;
  }
  memcpy(out, cell.chars, 6 * sizeof(uint32_t));
  out[6] = cell.width;
  out[7] = cell.attrs.bold | (cell.attrs.italic << 2) | ((cell.attrs.underline != 0) << 3)
    | (cell.attrs.blink << 4) | (cell.attrs.reverse << 5) | (cell.attrs.conceal << 6)
    | (cell.attrs.strike << 7);
  out[10] = !!VTERM_COLOR_IS_DEFAULT_FG(&cell.fg) | (!!VTERM_COLOR_IS_DEFAULT_BG(&cell.bg) << 1);
  vterm_screen_convert_color_to_rgb(t->screen, &cell.fg);
  vterm_screen_convert_color_to_rgb(t->screen, &cell.bg);
  out[8] = (cell.fg.rgb.red << 16) | (cell.fg.rgb.green << 8) | cell.fg.rgb.blue;
  out[9] = (cell.bg.rgb.red << 16) | (cell.bg.rgb.green << 8) | cell.bg.rgb.blue;
  return 1;
}

void vz_unsync(Terminal *t) {
  VTermValue value = {.boolean = 0};
  t->revision++;
  vterm_state_set_termprop(vterm_obtain_state(t->vt), VTERM_PROP_SYNCOUTPUT, &value);
}
const char *vz_title(Terminal *t) { return t->title; }
int vz_line_revision(Terminal *t, int history, int row) {
  if (history) {
    if (row < 0 || row >= t->count) return 0;
    return (int)t->history[(t->head + row) % HISTORY].revision;
  }
  return row >= 0 && row < t->rows ? (int)t->row_revision[row] : 0;
}
static uint32_t color(VTermColor c, int foreground) {
  if ((foreground && VTERM_COLOR_IS_DEFAULT_FG(&c)) || (!foreground && VTERM_COLOR_IS_DEFAULT_BG(&c))) return 256;
  if (VTERM_COLOR_IS_INDEXED(&c)) return c.indexed.idx;
  return 0x1000000u | ((uint32_t)c.rgb.red << 16) | ((uint32_t)c.rgb.green << 8) | c.rgb.blue;
}
int vz_line(Terminal *t, int history, int row, unsigned char *out, int size) {
  int cols = t->cols;
  Line *line = NULL;
  if (history) {
    if (row < 0 || row >= t->count) return 0;
    line = &t->history[(t->head + row) % HISTORY];
    cols = line->cols;
  } else if (row < 0 || row >= t->rows) return 0;
  if (size < cols * 40) return -1;
  int used = 0;
  for (int col = 0; col < cols; col++) {
    VTermScreenCell cell = {0};
    if (line) cell = line->cells[col];
    else if (!vterm_screen_get_cell(t->screen, (VTermPos){row,col}, &cell)) return -1;
    uint32_t words[10] = {0};
    if (cell.chars[0] != UINT32_MAX)
      for (int i = 0; i < 6 && cell.chars[i]; i++) words[i] = cell.chars[i];
    words[6] = cell.chars[0] == UINT32_MAX ? 0 : (unsigned)cell.width;
    words[7] = cell.attrs.bold | (cell.attrs.italic << 2) | ((cell.attrs.underline != 0) << 3)
      | (cell.attrs.blink << 4) | (cell.attrs.reverse << 5) | (cell.attrs.conceal << 6) | (cell.attrs.strike << 7);
    words[8] = color(cell.fg, 1); words[9] = color(cell.bg, 0);
    for (int w = 0; w < 10; w++)
      for (int byte = 0; byte < 4; byte++) out[col * 40 + w * 4 + byte] = (unsigned char)(words[w] >> (byte * 8));
    if (words[0] || words[6] != 1 || words[7] || words[8] != 256 || words[9] != 256) used = (col + 1) * 40;
  }
  return used;
}

void vz_color(Terminal *t, int index, int rgb) {
  VTermState *state = vterm_obtain_state(t->vt);
  VTermColor c;
  vterm_color_rgb(&c, (rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255);
  if (index >= 0) vterm_state_set_palette_color(state, index, &c);
  else {
    VTermColor fg, bg;
    vterm_state_get_default_colors(state, &fg, &bg);
    vterm_state_set_default_colors(state, index == -1 ? &c : &fg, index == -2 ? &c : &bg);
  }
}
void vz_geometry(Terminal *t, int width, int height) {
  if (width > 0 && width <= 1000) t->cell_width = width;
  if (height > 0 && height <= 1000) t->cell_height = height;
}
