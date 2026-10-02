//! The departure journal: capture of every row that crosses the top of the
//! primary active area, staged at the instant of the crossing and before any
//! retention decision, so durable capture is independent of live retention.
//!
//! Capture covers retained scrolling through explicit `growAndCaptureDeparture`
//! calls and the zero-retention in-place paths. `cursorDownScroll` and the
//! ordinary LF/IND `cursorScrollRegionUp` path stage before they erase or
//! rotate the departing top row. The alternate screen has no journal.
//!
//! A row-count shrink pushes rows out of the primary active area too, even
//! while the alternate screen holds the pane. `PageList.resize` stages those
//! rows before line-limit enforcement can prune them, exactly once.
//!
//! The odometer counts crossings and nothing else. Pruning, ED3, reset and
//! reflow never advance it, so a prune inside the same feed that produced a
//! row can never masquerade as a departure: the feed's own rows are already
//! staged and the odometer already counted them. The retained floor — the
//! odometer value below which nothing is retained in live history — is
//! `odometer - historyRows`, and rises with every row retention removes while
//! the odometer stands still.
//!
//! Staging is bounded. The bound is the byte budget the embedder sets (the
//! default is `default_max_bytes`); a crossing the bound refuses advances the
//! odometer and counts as a refusal, and the refusal is surfaced through
//! `Status` — never dropped in silence. An allocation failure while staging a
//! row is surfaced the same way: the crossing still happens, the row is still
//! counted, and the drain reports what is missing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const PageList = @import("PageList.zig");
const pagepkg = @import("page.zig");
const stylepkg = @import("style.zig");

const Cell = pagepkg.Cell;
const Style = stylepkg.Style;
const StyleId = stylepkg.Id;

/// The staging bound when the embedder has not set one. The embedder that
/// owns a byte budget (the pool every stage of its capture spends) sets it
/// through the terminal option; this default only bounds what an embedder
/// that never configured capture would otherwise let a single feed stage.
pub const default_max_bytes: usize = 8 * 1024 * 1024;

/// One departed row, self-contained: the cells as they were at the crossing,
/// the styles those cells referenced (a page's style ids are page-relative
/// and die with the page, so each entry carries its own table), and the
/// grapheme clusters of multi-codepoint cells, encoded as UTF-8.
///
/// `refused_before` carries the crossings the bound refused immediately
/// before this row was staged: their odometer values are
/// `[odometer - refused_before, odometer)`. A consumer draining this entry
/// knows exactly which rows it never received.
pub const Entry = struct {
    odometer: u64,
    refused_before: u64,
    cols: u16,
    wrap: bool,
    wrap_continuation: bool,
    cells: []Cell,
    /// Entry-local style table. A cell's `style_id` indexes this table; id 0
    /// is the default style and `styles[0]` is never read.
    styles: []Style,
    /// Grapheme clusters as UTF-8, referenced by `clusters`.
    utf8: []u8,
    /// The cells that carry text, in cell order, with each cluster's
    /// UTF-8 span in `utf8`. Cells not listed carry no text.
    clusters: []Cluster,

    pub const Cluster = struct {
        cell: u16,
        off: u32,
        len: u16,
    };

    /// The bytes this entry charges against the staging bound: its whole
    /// allocation footprint, not a symbolic per-row constant.
    pub fn byteSize(self: *const Entry) usize {
        return @sizeOf(Entry) +
            self.cells.len * @sizeOf(Cell) +
            self.styles.len * @sizeOf(Style) +
            self.utf8.len +
            self.clusters.len * @sizeOf(Cluster);
    }

    /// The style of one of this entry's cells: the entry-local table, or the
    /// default style for id 0. This is the same value a live grid reference
    /// would have resolved for the cell at the moment of the crossing.
    pub fn styleOf(self: *const Entry, cell: Cell) Style {
        if (cell.style_id == 0) return .{};
        // Entry-local ids are 1-based over the table: id 0 is the default
        // style and never indexes it.
        return self.styles[cell.style_id - 1];
    }

    /// The UTF-8 cluster of one of this entry's cells, if it carries text.
    /// A textual cell always has an entry; a cell without text never does.
    pub fn clusterOf(self: *const Entry, cell_index: usize) ?[]const u8 {
        // Clusters are in cell order; a cursor walk finds each in amortized
        // constant time. Linear search keeps the table allocation minimal.
        for (self.clusters) |c| {
            if (c.cell == cell_index) return self.utf8[c.off .. c.off + c.len];
        }
        return null;
    }
};

/// The state a consumer reads between drains. `peak_bytes`, `refused_rows`
/// and `refused_from` are read-and-clear: each call hands over what happened
/// since the previous call, so a consumer that drains on every write sees
/// each refusal exactly once.
pub const Status = struct {
    odometer: u64,
    pending: usize,
    staged_bytes: usize,
    peak_bytes: usize,
    refused_rows: u64,
    refused_from: u64,
};

/// The departure journal. One instance serves the primary screen of one
/// terminal; the alternate screen departs nothing and never stages here.
pub const Departures = struct {
    alloc: Allocator,

    /// Monotonic count of crossings, journaled or refused.
    odometer: u64 = 0,

    /// The staging bound in bytes. Lowering it never drops what is already
    /// staged; it refuses crossings until a drain frees their bytes.
    max_bytes: usize = default_max_bytes,

    staged_bytes: usize = 0,
    peak_bytes: usize = 0,

    /// Crossings refused since the last staged entry. They are the most
    /// recent crossings (nothing can cross without being staged or refused),
    /// so the span is `[odometer - refused_pending, odometer)`.
    refused_pending: u64 = 0,

    entries: std.ArrayListUnmanaged(Entry) = .empty,
    /// Index of the oldest entry not yet drained. Entries below it are freed
    /// and their space reusable; the list is compacted when it empties.
    head: usize = 0,

    pub fn init(alloc: Allocator) Departures {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Departures) void {
        for (self.entries.items[self.head..]) |e| self.freeEntry(e);
        self.entries.deinit(self.alloc);
        self.* = undefined;
    }

    /// Set the staging bound. `null` restores the default. The bound is a
    /// pool the embedder owns; this only records it.
    pub fn setMaxBytes(self: *Departures, max: ?usize) void {
        self.max_bytes = max orelse default_max_bytes;
    }

    /// Entries staged and not yet drained.
    pub fn pending(self: *const Departures) usize {
        return self.entries.items.len - self.head;
    }

    /// The number of history rows above the active area of `pages`. This is
    /// the depth a live history read reports, and the subtrahend of the
    /// retained floor.
    pub fn historyRows(pages: *const PageList) usize {
        // Saturating: a partially-built clone during a reflow can hold
        // fewer rows than its active area, and that is zero history, not
        // a negative one.
        return pages.total_rows -| pages.rows;
    }

    /// Read the journal's state, handing over (and clearing) the peak and
    /// the trailing refusal span. Callers that drain after every write see
    /// every refusal exactly once.
    pub fn status(self: *Departures) Status {
        const s = Status{
            .odometer = self.odometer,
            .pending = self.pending(),
            .staged_bytes = self.staged_bytes,
            .peak_bytes = self.peak_bytes,
            .refused_rows = self.refused_pending,
            .refused_from = self.odometer - self.refused_pending,
        };
        self.peak_bytes = self.staged_bytes;
        self.refused_pending = 0;
        return s;
    }

    /// The oldest staged entry, without draining it. The entry stays valid
    /// until `popOldest` runs; staging more entries does not invalidate it.
    pub fn peekOldest(self: *Departures) ?*Entry {
        if (self.head == self.entries.items.len) return null;
        return &self.entries.items[self.head];
    }

    /// Drain the oldest staged entry, freeing it. The bytes it charged are
    /// returned to the staging budget.
    pub fn popOldest(self: *Departures) void {
        const e = self.entries.items[self.head];
        self.staged_bytes -= e.byteSize();
        self.freeEntry(e);
        self.entries.items[self.head] = undefined;
        self.head += 1;
        if (self.head == self.entries.items.len) {
            self.entries.clearRetainingCapacity();
            self.head = 0;
        }
    }

    /// Stage the top row of the active area of `pages`: the row about to
    /// cross. Called before the mutation that moves it, so the row is read
    /// at the last instant it certainly exists. Infallible by contract: a
    /// row that cannot be staged (bound, or allocation failure) is a refusal
    /// the crossing still counts and `Status` still surfaces.
    pub fn captureTopRow(self: *Departures, pages: *PageList) void {
        const pin = pages.pin(.{ .active = .{ .x = 0, .y = 0 } }) orelse {
            // A screen without a valid top-left pin has no active area to
            // cross. Nothing to count and nothing to lose.
            return;
        };
        self.capturePin(pin);
    }

    /// Stage `count` rows starting at history position `from` (oldest of the
    /// range first). The rows a reflow just pushed into history cross at
    /// this moment; they are captured before anything can erase them.
    pub fn captureHistoryRows(
        self: *Departures,
        pages: *PageList,
        from: usize,
        to: usize,
    ) void {
        var y = from;
        while (y < to) : (y += 1) {
            const pin = pages.pin(.{
                .history = .{ .x = 0, .y = @intCast(y) },
            }) orelse {
                // The page list changed shape under the range (it cannot:
                // this runs between the mutation and the next one) or the
                // position never existed. Count the crossing and refuse it
                // rather than silently skipping it.
                self.refuse();
                continue;
            };
            self.capturePin(pin);
        }
    }

    fn capturePin(self: *Departures, pin: PageList.Pin) void {
        self.odometer += 1;

        var entry: Entry = .{
            .odometer = self.odometer,
            .refused_before = self.refused_pending,
            .cols = 0,
            .wrap = false,
            .wrap_continuation = false,
            .cells = &.{},
            .styles = &.{},
            .utf8 = &.{},
            .clusters = &.{},
        };
        self.refused_pending = 0;

        const rac = pin.rowAndCell();
        entry.wrap = rac.row.wrap;
        entry.wrap_continuation = rac.row.wrap_continuation;

        const cells = pin.cells(.all);
        entry.cols = @intCast(cells.len);

        // Stage the row, or refuse it whole. A partially staged row would be
        // worse than a refused one: the consumer would read a row that never
        // existed. Every failure path below lands in one refusal.
        self.stageCells(pin, cells, &entry) catch {
            self.freeEntry(entry);
            self.refusedAfterStage();
            return;
        };

        const size = entry.byteSize();
        if (self.staged_bytes + size > self.max_bytes) {
            self.freeEntry(entry);
            self.refusedAfterStage();
            return;
        }

        self.entries.append(self.alloc, entry) catch {
            self.freeEntry(entry);
            self.refusedAfterStage();
            return;
        };

        self.staged_bytes += size;
        if (self.staged_bytes > self.peak_bytes) self.peak_bytes = self.staged_bytes;
    }

    /// Fill `entry` from the row at `pin`. Fails only on allocation
    /// failure; the caller turns failure into a refusal.
    fn stageCells(
        self: *Departures,
        pin: PageList.Pin,
        cells: []Cell,
        entry: *Entry,
    ) Allocator.Error!void {
        const dup = try self.alloc.dupe(Cell, cells);
        // Transfer ownership immediately so capturePin's failure cleanup can
        // free this buffer if a later style/grapheme allocation fails.
        entry.cells = dup;

        // The style table is entry-local: remap every distinct page style id
        // the row uses to its own index. Id 0 stays 0 (the default style).
        var styles: std.ArrayListUnmanaged(Style) = .empty;
        errdefer styles.deinit(self.alloc);
        for (dup) |*cell| {
            if (cell.style_id == 0) continue;
            const resolved = pin.style(cell);
            var local: StyleId = 0;
            for (styles.items, 1..) |s, i| {
                if (s.eql(resolved)) {
                    local = @intCast(i);
                    break;
                }
            }
            if (local == 0) {
                try styles.append(self.alloc, resolved);
                local = @intCast(styles.items.len);
            }
            cell.style_id = local;
        }

        // Text bytes: encode every textual cell's cluster (its own
        // codepoint, then any additional codepoints of a multi-codepoint
        // grapheme) to UTF-8 once, at capture, so the drain copies bytes
        // and resolves nothing. A cell without text carries no bytes; a
        // cell with text always does.
        var utf8: std.ArrayListUnmanaged(u8) = .empty;
        errdefer utf8.deinit(self.alloc);
        var clusters: std.ArrayListUnmanaged(Entry.Cluster) = .empty;
        errdefer clusters.deinit(self.alloc);
        for (dup, 0..) |cell, i| {
            if (!cell.hasText()) continue;
            const extra = if (cell.hasGrapheme()) pin.grapheme(&cells[i]) orelse null else null;
            const off: u32 = @intCast(utf8.items.len);
            var enc: [4]u8 = undefined;
            try appendCodepoint(self.alloc, &utf8, cell.codepoint(), &enc);
            if (extra) |cps| {
                for (cps) |cp| try appendCodepoint(self.alloc, &utf8, cp, &enc);
            }
            const len: u16 = @intCast(utf8.items.len - off);
            if (len == 0) continue;
            try clusters.append(self.alloc, .{
                .cell = @intCast(i),
                .off = off,
                .len = len,
            });
        }

        entry.styles = try styles.toOwnedSlice(self.alloc);
        entry.utf8 = try utf8.toOwnedSlice(self.alloc);
        entry.clusters = try clusters.toOwnedSlice(self.alloc);
    }

    fn appendCodepoint(
        alloc: Allocator,
        list: *std.ArrayListUnmanaged(u8),
        cp: u21,
        enc: *[4]u8,
    ) Allocator.Error!void {
        const n = std.unicode.utf8Encode(cp, enc) catch {
            // A codepoint the row should not hold cannot be encoded; the
            // cluster this belongs to is read without this codepoint. The
            // entry stays truthful about everything it does carry.
            return;
        };
        try list.appendSlice(alloc, enc[0..n]);
    }

    /// A crossing that could not be staged. The odometer has already counted
    /// it (the crossing happens regardless); the refusal is recorded so the
    /// consumer learns the row it never received.
    fn refuse(self: *Departures) void {
        self.odometer += 1;
        self.refused_pending += 1;
    }

    /// The refusal path of `capturePin`, after its entry was counted and
    /// built: roll the staging back into a refusal of this one row.
    fn refusedAfterStage(self: *Departures) void {
        // capturePin already advanced the odometer for this row; the entry
        // it attached that count to is gone, so the refusal inherits it.
        self.refused_pending += 1;
    }

    fn freeEntry(self: *Departures, e: Entry) void {
        if (e.cells.len > 0) self.alloc.free(e.cells);
        if (e.styles.len > 0) self.alloc.free(e.styles);
        if (e.utf8.len > 0) self.alloc.free(e.utf8);
        if (e.clusters.len > 0) self.alloc.free(e.clusters);
    }
};

test "a refused crossing is surfaced, never silent" {
    const testing = std.testing;
    const Screen = @import("Screen.zig");

    var s = try Screen.init(testing.io, testing.allocator, .{
        .cols = 80,
        .rows = 4,
        .max_scrollback_bytes = null,
    });
    defer s.deinit();

    var d = Departures.init(testing.allocator);
    defer d.deinit();
    s.departures = &d;
    s.pages.departures = &d;
    // A bound too small for a single row: every crossing of this screen is
    // refused, and every refusal is counted.
    d.setMaxBytes(1);

    try s.testWriteString("one\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix\r\n");

    const before = d.odometer;
    const st = statusOnce(&d);
    try testing.expect(st.refused_rows > 0);
    try testing.expectEqual(st.refused_rows, before - st.refused_from);
    try testing.expectEqual(@as(usize, 0), st.pending);
    // The refused span is the newest crossings: it ends at the odometer.
    try testing.expectEqual(before, st.odometer);
    // Read-and-clear: a second read reports nothing new.
    const st2 = statusOnce(&d);
    try testing.expectEqual(@as(u64, 0), st2.refused_rows);
    try testing.expectEqual(@as(usize, 0), st2.peak_bytes);
}

test "staging is charged and the peak is handed over" {
    const testing = std.testing;
    const Screen = @import("Screen.zig");

    var s = try Screen.init(testing.io, testing.allocator, .{
        .cols = 80,
        .rows = 4,
        .max_scrollback_bytes = null,
    });
    defer s.deinit();

    var d = Departures.init(testing.allocator);
    defer d.deinit();
    s.departures = &d;
    s.pages.departures = &d;

    try s.testWriteString("one\r\ntwo\r\nthree\r\nfour\r\nfive\r\n");

    const st = statusOnce(&d);
    try testing.expect(st.pending > 0);
    try testing.expect(st.staged_bytes > 0);
    try testing.expect(st.peak_bytes >= st.staged_bytes);

    // Draining returns the bytes to the budget.
    const charged = st.staged_bytes;
    while (d.peekOldest() != null) d.popOldest();
    const st2 = statusOnce(&d);
    try testing.expectEqual(@as(usize, 0), st2.staged_bytes);
    try testing.expect(st2.peak_bytes >= charged);
}

fn statusOnce(d: *Departures) Status {
    return d.status();
}

test "allocation failures while staging a row free every partial allocation" {
    const testing = std.testing;
    const Screen = @import("Screen.zig");

    var s = try Screen.init(testing.io, testing.allocator, .{
        .cols = 40,
        .rows = 3,
        .max_scrollback_bytes = null,
    });
    defer s.deinit();
    try s.testWriteString("\x1b[1;31mred \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F466}");

    // A successful row stage gives the number of allocation points to fail
    // one by one below. The row exercises cells, styles, UTF-8 clusters and
    // the journal's entry list.
    var baseline = testing.FailingAllocator.init(testing.allocator, .{});
    var baseline_departures = Departures.init(baseline.allocator());
    baseline_departures.captureTopRow(&s.pages);
    const allocation_count = baseline.alloc_index;
    try testing.expect(allocation_count > 1);
    baseline_departures.deinit();
    try testing.expectEqual(baseline.allocated_bytes, baseline.freed_bytes);

    var fail_index: usize = 0;
    while (fail_index < allocation_count) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });
        var departures = Departures.init(failing.allocator());
        departures.captureTopRow(&s.pages);
        try testing.expect(failing.has_induced_failure);
        const status = departures.status();
        try testing.expectEqual(@as(usize, 0), status.pending);
        try testing.expectEqual(@as(u64, 1), status.refused_rows);
        try testing.expectEqual(@as(u64, 1), status.odometer);
        departures.deinit();
        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "zero retention journals every scrolled row" {
    // DONE WHEN (a): with no scrollback at all, a row that crosses the top
    // of the active area is erased in place and no depth ever grows; the
    // journal still holds every one of them, in order, with the screen rows
    // beside them making the whole feed.
    const testing = std.testing;
    const Screen = @import("Screen.zig");

    var s = try Screen.init(testing.io, testing.allocator, .{
        .cols = 20,
        .rows = 5,
        .max_scrollback_bytes = 0,
    });
    defer s.deinit();
    try testing.expect(s.no_scrollback);

    var d = Departures.init(testing.allocator);
    defer d.deinit();
    s.departures = &d;
    s.pages.departures = &d;

    var feed: std.ArrayList(u8) = .empty;
    defer feed.deinit(testing.allocator);
    var want: std.ArrayList([]const u8) = .empty;
    defer {
        for (want.items) |w| testing.allocator.free(w);
        want.deinit(testing.allocator);
    }
    const lines = [_][]const u8{ "zero-1", "zero-2", "zero-3", "zero-4", "zero-5", "zero-6", "zero-7", "zero-8" };
    for (lines) |line| {
        try feed.appendSlice(testing.allocator, line);
        try feed.appendSlice(testing.allocator, "\n");
        try want.append(testing.allocator, try testing.allocator.dupe(u8, line));
    }
    try s.testWriteString(feed.items);

    // The journal plus the visible screen is the whole feed, in order.
    var got: std.ArrayList([]const u8) = .empty;
    while (d.peekOldest()) |e| {
        try got.append(testing.allocator, try entryText(testing.allocator, e));
        d.popOldest();
    }
    // The screen still shows the newest rows (5 of 8 left the screen).
    var y: usize = 0;
    while (y < s.pages.rows) : (y += 1) {
        const pin = s.pages.pin(.{ .active = .{ .x = 0, .y = @intCast(y) } }).?;
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(testing.allocator);
        for (pin.cells(.all)) |cell| {
            if (cell.hasText()) {
                var enc: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cell.codepoint(), &enc) catch continue;
                try text.appendSlice(testing.allocator, enc[0..n]);
            }
        }
        const row_text = try testing.allocator.dupe(u8, std.mem.trimEnd(u8, text.items, " "));
        // The screen's final row is the blank row the feed's last newline
        // opened; it holds no content to lose, so the comparison is over
        // the rows that do.
        if (row_text.len > 0) try got.append(testing.allocator, row_text) else testing.allocator.free(row_text);
    }
    defer {
        for (got.items) |g| testing.allocator.free(g);
        got.deinit(testing.allocator);
    }

    try testing.expectEqual(want.items.len, got.items.len);
    for (want.items, got.items) |w, g| try testing.expectEqualStrings(w, g);
    // No row was refused and the odometer counted exactly the crossings.
    const st = statusOnce(&d);
    try testing.expectEqual(@as(u64, 0), st.refused_rows);
    try testing.expectEqual(@as(usize, 0), st.pending);
}

test "a same-feed prune advances the floor and never the odometer" {
    // DONE WHEN (b): the byte bound prunes history pages inside the very
    // feed that produced them. The odometer counts only that feed's own
    // crossings, the journal holds exactly those rows, and the retained
    // floor rises by the pruned rows while the odometer stands still.
    const testing = std.testing;
    const Screen = @import("Screen.zig");

    var s = try Screen.init(testing.io, testing.allocator, .{
        .cols = 20,
        .rows = 5,
        // A line bound just above the page minimum: scrolling far past
        // it prunes whole pages inside this one feed.
        .max_scrollback_lines = 260,
    });
    defer s.deinit();

    var d = Departures.init(testing.allocator);
    defer d.deinit();
    s.departures = &d;
    s.pages.departures = &d;

    var feed: std.ArrayList(u8) = .empty;
    defer feed.deinit(testing.allocator);
    var want: std.ArrayList([]const u8) = .empty;
    defer {
        for (want.items) |w| testing.allocator.free(w);
        want.deinit(testing.allocator);
    }
    const total = 900;
    var i: usize = 0;
    while (i < total) : (i += 1) {
        var buf: [32]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "prune-{d:0>4}", .{i});
        try feed.appendSlice(testing.allocator, line);
        try feed.appendSlice(testing.allocator, "\n");
        try want.append(testing.allocator, try testing.allocator.dupe(u8, line));
    }
    try s.testWriteString(feed.items);

    // Every departure was staged, none refused, and the rows are the exact
    // oldest prefix of the feed, not pages retention pruned on the way.
    var drained_rows: std.ArrayList([]const u8) = .empty;
    defer {
        for (drained_rows.items) |line| testing.allocator.free(line);
        drained_rows.deinit(testing.allocator);
    }
    var prev: u64 = 0;
    while (d.peekOldest()) |e| {
        try testing.expect(e.odometer > prev);
        prev = e.odometer;
        try drained_rows.append(testing.allocator, try entryText(testing.allocator, e));
        d.popOldest();
    }
    try testing.expect(drained_rows.items.len > 0);
    try testing.expectEqual(d.odometer, drained_rows.items.len);
    for (drained_rows.items, 0..) |line, row_index| {
        try testing.expectEqualStrings(want.items[row_index], line);
    }

    // The prune removed rows: the floor rose past them while the odometer
    // stood still — it counted only the feed's own crossings, exactly the
    // rows the drain returned, whatever retention did meanwhile.
    const depth = Departures.historyRows(&s.pages);
    try testing.expect(d.odometer > depth);
    const retained_floor = d.odometer - depth;
    try testing.expect(retained_floor > 0);
    try testing.expectEqual(d.odometer, retained_floor + depth);

    const st = statusOnce(&d);
    try testing.expectEqual(@as(u64, 0), st.refused_rows);
}

test "a shrink pushes its rows once and a refill journals nothing" {
    const testing = std.testing;
    const Screen = @import("Screen.zig");

    var s = try Screen.init(testing.io, testing.allocator, .{
        .cols = 20,
        .rows = 8,
        .max_scrollback_bytes = null,
    });
    defer s.deinit();

    var d = Departures.init(testing.allocator);
    defer d.deinit();
    s.departures = &d;
    s.pages.departures = &d;

    try s.testWriteString("fill-1\nfill-2\nfill-3\nfill-4\nfill-5\nfill-6\nfill-7\nfill-8\n");
    while (d.peekOldest() != null) d.popOldest();
    const after_fill = d.odometer;

    // A shrink by three rows pushes the three top rows out of the active
    // area: they cross, once, at the resize.
    try s.resize(.{ .cols = 20, .rows = 5, .reflow = true });
    var pushed: usize = 0;
    while (d.peekOldest()) |e| {
        _ = e;
        d.popOldest();
        pushed += 1;
    }
    try testing.expectEqual(@as(usize, 3), pushed);
    try testing.expectEqual(after_fill + 3, d.odometer);

    // Growing back pulls those rows out of history onto the screen: no
    // crossing, no journal entry, no odometer movement.
    try s.resize(.{ .cols = 20, .rows = 8, .reflow = true });
    try testing.expectEqual(@as(usize, 0), d.pending());
    try testing.expectEqual(after_fill + 3, d.odometer);
}

/// Render one journal entry's text the way a consumer reads it: every
/// cell's codepoint or recorded cluster, in order, trailing blanks trimmed.
fn entryText(alloc: Allocator, e: *const Entry) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(alloc);
    for (e.cells, 0..) |cell, i| {
        if (cell.hasGrapheme()) {
            if (e.clusterOf(i)) |cluster| {
                try text.appendSlice(alloc, cluster);
                continue;
            }
        }
        if (cell.hasText()) {
            var enc: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cell.codepoint(), &enc) catch continue;
            try text.appendSlice(alloc, enc[0..n]);
        }
    }
    const trimmed = std.mem.trimEnd(u8, text.items, " ");
    defer text.deinit(alloc);
    return alloc.dupe(u8, trimmed);
}
