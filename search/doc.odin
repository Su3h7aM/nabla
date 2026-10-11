// Package search is a standalone file-discovery and content-search library: find matches paths and grep matches file
// lines over one Index per root. It knows nothing about sessions, tools, or models; plain data goes in and owned rows come out.
//
// An Index holds one root and owns exactly two allocations of its allocator: a paths buffer and the file list, whose strings
// view that buffer. index_make scans the root once and queries reuse the list without walking. index_update rescans and bumps
// the generation. index_refresh_if_stale rescans only when the root directory's mtime moved, which sees entries created,
// removed, or renamed directly under the root; an edit to an existing file or a change below the top level needs index_update.
// One owner mutates an Index. Queries borrow it, may run on any thread, and never run concurrently with an update. The zero
// Index is inert.
//
// A scan prunes hidden directories, .git, and the DENY_DIRS, indexes hidden files, and skips symlinks and other non-regular
// files without following them. Binary, oversize, and unreadable files are skipped by grep and counted by cause in every
// result's Skip_Breakdown; a skip never fails a query, and find still lists those files. glob_valid reports whether a glob
// filter can be read, and find and grep return Invalid_Glob for one that cannot.
//
// Inside a Git or Jujutsu repository, meaning a .git or .jj entry in the root, an ancestor, or a directory the scan reaches, a
// scan also leaves out what .gitignore files and .git/info/exclude ignore, with Git's pattern syntax and precedence; an ignored
// directory is never entered, so a negation cannot re-include a file below it. Ignored files are not counted as skips, and
// outside a repository no ignore rule applies.
//
// find and grep match exactly first. Only on zero exact matches do they run one labeled, typo-tolerant fuzzy fallback, and the
// result's notice names it; a true non-match stays empty with no notice. grep in Plain mode first retries a multi-word pattern
// without its leading word. grep in Regex mode never recovers, and an invalid regular expression falls back to a literal search
// with a notice. Exact rows are never capped; grep's fuzzy fallback keeps at most APPROX_CAP.
//
// find ranks exact hits by match quality. With Find_Query.frecency and now, it reranks them by access and modification
// scores. grep orders files by frecency when given and otherwise by path; it re-reads only the files its page touches, and
// rows inside a file follow line order.
//
// A cursor is the plain text "<generation>.<offset>.<16 hex fnv64a of root>". Parsing is strict: canonical decimal numbers,
// lowercase hex, exactly three fields. The hash is a check, not a secret. A malformed cursor or one from another root is
// Invalid_Cursor, and one from before an index_update is Stale_Cursor. An offset past the end returns an empty page. A limit at
// or below zero means every row.
//
// Frecency holds a decayed access weight per absolute path, with a 3-day half-life and a 7-day window. Its optional log is
// append-only and compacted when opened. modification_score maps a file's age to a bonus. After frecency_open, recording and
// scoring are safe from any thread.
//
// parallel_for spreads index walks and grep passes across worker threads, and the calling thread is one of the workers.
package search
