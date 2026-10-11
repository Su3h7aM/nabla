// Package fuzzy scores typo-tolerant matches of one query against many
// candidates.
//
// A candidate places in tiers, best first: Exact, Prefix, Substring, then a
// DP alignment that is a Subsequence or, when it needed edits, a Typo. An edit
// is a substitution, a deletion, or an adjacent transposition of query bytes.
// A Pattern allows max_typos edits, by default one per four query bytes. An
// edit at the head of the query must start on a word boundary and may drop
// only leading bytes the candidate lacks. Case is smart: a query holding an
// uppercase byte matches case-sensitively, otherwise case-insensitively.
// Matching is bytewise, so non-ASCII bytes match only themselves.
//
// The normalized score runs 0..1 whatever the query length: 1 is an exact
// hit and MATCH_THRESHOLD is the lowest value match_kept accepts. A true
// non-match is kind None with zero scores.
//
// Before the DP, two filters rule out candidates that cannot align within the
// budget: a byte-presence count and, for queries of at most 64 bytes, a
// bit-parallel longest-common-subsequence bound. Queries of at most 16 bytes
// with a budget below 4 run the DP over all query positions at once with SIMD
// lanes; others run the scalar form with the same results.
//
// A Pattern compiles the query once and owns the DP rows, so scoring
// allocates nothing; the rows are call state, so use one Pattern per thread.
// Top_K streams candidates through a fixed backing of K hits, and match_list
// returns the best hits of a slice. The package does no I/O.
package fuzzy
