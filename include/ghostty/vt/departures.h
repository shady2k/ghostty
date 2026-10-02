/**
 * @file departures.h
 *
 * The departure journal: durable capture of every row that crosses the top
 * of the primary active area, taken before any retention decision, so what
 * a durable record keeps is independent of what live retention keeps.
 *
 * Durable capture and live retention are two different budgets answering
 * two different questions. Live retention (the scrollback limits) decides
 * what the terminal can still SHOW; the journal decides what it can still
 * REPORT. A row that scrolled off with zero scrollback configured used to
 * be erased in place before any reader could see it, and a feed whose own
 * scrolling triggered scrollback pruning conflated its departures with the
 * pruned pages. The journal fixes both by staging the row at the exact
 * moment it crosses the top of the primary active area - the last instant
 * its cells certainly exist - on both crossing paths: the scrollback
 * append and the zero-retention in-place erase.
 *
 * The journal is a PULL journal: the embedder drains it. The fork holds no
 * callback and no queue bound for a slow consumer; it holds a bounded
 * write-ahead stage whose peak is charged to a byte budget the embedder
 * owns (GHOSTTY_TERMINAL_OPT_DEPARTURE_MAX_BYTES), and a fully drained
 * journal is the normal state after every ghostty_terminal_vt_write() and
 * every ghostty_terminal_resize().
 *
 * Marker and block attribution stay with the embedder. The journal carries
 * rows and odometer arithmetic and nothing else: no nonce, no interval
 * state, no end markers. The odometer is a monotonic count of primary
 * crossings - journaled or refused - and is never advanced by pruning,
 * ED3, reset or reflow, so a prune inside the very feed that produced a
 * row can never masquerade as a departure.
 *
 * Alternate-screen scrolling stages nothing. A resize that pushes rows out
 * of the primary active area (a shrink, including one taken while the
 * alternate screen holds the pane) stages those rows once, at the resize,
 * and not again when the alternate screen returns.
 */

#ifndef GHOSTTY_VT_DEPARTURES_H
#define GHOSTTY_VT_DEPARTURES_H

#include <ghostty/vt/types.h>
#include <ghostty/vt/style.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * The state of the departure journal between drains.
 *
 * @ingroup departures
 *
 * peak_bytes, refused_rows and refused_from are handed over by each
 * ghostty_terminal_vt_departure_status() call: they report what happened
 * since the previous call, so a consumer that drains after every write
 * sees each refusal exactly once.
 */
typedef struct {
  /** Monotonic count of primary-screen crossings, journaled or refused. */
  uint64_t odometer;

  /** Entries staged and not yet drained. Delimits what to drain; never an
      interval boundary. */
  size_t pending;

  /** Bytes currently charged against the journal's bound: row buffers plus
      the full Entry-list capacity, including unused slots. */
  size_t staged_bytes;

  /** High-water charged bytes since the previous status call, including
      temporary capture and Entry-list growth copies. */
  size_t peak_bytes;

  /** Crossings the bound refused since the previous status call. A
      refusal is pool exhaustion surfaced: the crossing happened, the
      odometer counted it, the row's contents were not retained. */
  uint64_t refused_rows;

  /** The odometer boundary immediately before the trailing refused span.
      The span is [refused_from, refused_from + refused_rows). */
  uint64_t refused_from;
} GhosttyTerminalDepartureStatus;

/**
 * One cell of a departed row, materialized at the instant of the crossing.
 *
 * @ingroup departures
 *
 * This is the same reading a grid reference gives for a live row: text,
 * width, style and the cell's grapheme cluster. The cluster bytes live in
 * the drain call's UTF-8 buffer at grapheme_off/grapheme_len; a cell with
 * no recorded cluster holds its cluster (if any) fully inside its own
 * codepoint, which has_text/has_text alone describe.
 */
typedef struct {
  /** Whether the cell has text to render. */
  bool has_text;

  /** Whether the cell holds a double-width character. */
  bool wide;

  /** Whether the cell carries a non-default style. */
  bool styled;

  /** The cell's style at the crossing. Meaningful when styled is set. */
  GhosttyStyle style;

  /** Offset of the cell's grapheme cluster in the drain's UTF-8 buffer. */
  uint32_t grapheme_off;

  /** Length of the cell's grapheme cluster in bytes. */
  uint16_t grapheme_len;
} GhosttyTerminalDepartureCell;

/**
 * The head of a drained departure entry.
 *
 * @ingroup departures
 */
typedef struct {
  /** The odometer value this crossing produced. */
  uint64_t odometer;

  /** Crossings the bound refused immediately before this row was staged;
      their odometer-boundary span is [odometer - refused_before, odometer). */
  uint64_t refused_before;

  /** The row's width at the moment it crossed. A resize never rewrites a
      departed row. */
  uint16_t cols;

  /** Whether the row was soft-wrapped at the crossing. */
  bool wrap;

  /** Whether the row continued a soft-wrapped row above it. */
  bool continuation;
} GhosttyTerminalDepartureRow;

/**
 * Read the departure journal's status.
 *
 * @ingroup departures
 *
 * The primary screen's journal is read regardless of which screen is
 * active. peak_bytes, refused_rows and refused_from are read-and-clear:
 * each call hands over what happened since the previous call.
 *
 * @param terminal The terminal handle
 * @param[out] out The status to fill
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE for a NULL
 *         handle or output
 */
GhosttyResult ghostty_terminal_vt_departure_status(
    GhosttyTerminal terminal,
    GhosttyTerminalDepartureStatus* out);

/**
 * Drain the oldest staged departure, if any.
 *
 * @ingroup departures
 *
 * On GHOSTTY_SUCCESS the entry is popped and its bytes return to the
 * staging bound; the row's cells are written to out_cells and its
 * grapheme cluster bytes to out_graphemes (cell i's cluster is
 * out_graphemes[grapheme_off .. grapheme_off + grapheme_len] as carried
 * by out_cells[i]).
 *
 * GHOSTTY_OUT_OF_SPACE leaves the entry staged: out_info is filled
 * first, out_needed (when given) receives the grapheme capacity the row
 * needs, and the caller retries with out_cells holding at least
 * info.cols entries and out_graphemes at least *out_needed bytes.
 * Passing NULL for either buffer also returns GHOSTTY_OUT_OF_SPACE
 * after filling out_info, which is how a caller sizes its buffers.
 *
 * GHOSTTY_NO_VALUE means the journal is drained: the normal state after
 * every write and every resize.
 *
 * @param terminal The terminal handle
 * @param[out] out_info The row's head, always filled unless NULL
 * @param[out] out_cells Cell facts, capacity cells_cap
 * @param cells_cap How many cells out_cells holds
 * @param[out] out_graphemes Grapheme cluster bytes
 * @param graphemes_cap How many bytes out_graphemes holds
 * @param[out] out_needed Required grapheme capacity on out-of-space
 * @return GHOSTTY_SUCCESS, GHOSTTY_OUT_OF_SPACE (retry, entry kept),
 *         GHOSTTY_NO_VALUE (drained), or GHOSTTY_INVALID_VALUE
 */
GhosttyResult ghostty_terminal_vt_departure_drain_row(
    GhosttyTerminal terminal,
    GhosttyTerminalDepartureRow* out_info,
    GhosttyTerminalDepartureCell* out_cells,
    size_t cells_cap,
    uint8_t* out_graphemes,
    size_t graphemes_cap,
    size_t* out_needed);

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_DEPARTURES_H */
