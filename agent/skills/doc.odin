// Package skills reads the Agent Skills format: a set of roots, the metadata a skill
// declares in its SKILL.md, and the verified read of a skill's body.
//
// It is a library, not part of the harness. It imports only `core:`, and it knows nothing
// about sessions, models, or prompts: a caller supplies the roots in its own priority
// order and decides what a skill is for.
//
// # Catalog
//
// discover reads the roots in the order it is given them. A name found in an earlier root
// wins over the same name later, and the loser is recorded as a shadowed diagnostic. A
// root is canonicalized before it is read, and one that resolves to a directory another
// root already named is recorded as an alias and dropped, so a skill is never read twice
// through two paths. The walk enters every directory once per device and inode, which ends
// a symlink cycle, skips version-control and `node_modules` directories, and reads entries
// in bytewise path order. A directory holds a skill when it holds a regular SKILL.md; a
// file that declares no usable metadata is recorded as a diagnostic rather than failing
// the scan, and the catalog counts under `omitted` the diagnostics a failed allocation
// dropped.
//
// A name declared twice inside one root is ambiguous and enters no catalog. A catalog's
// skills are sorted by name, so find looks one up by binary search, and every diagnostic
// names the root and the file it came from.
//
// # Metadata
//
// SKILL.md opens with a frontmatter block delimited by `---` and holding two keys, `name`
// and `description`, both required and both refused when repeated. The subset is the one
// this package reads: plain, single-quoted, double-quoted, literal, and folded scalars.
// Flow collections, anchors, and tags are unsupported rather than misread, and an
// unsupported form is reported with the line it is on. The declared name must be canonical
// and must match the directory name, and the declared description is normalized to single
// spaces between its words. Name and description have the format's own limits of 64 bytes
// and 1024 runes; a file that breaks them is not a skill.
//
// Metadata is digested, so a body can be checked against the catalog it was selected with.
//
// # Loading
//
// load reads one skill's body through one descriptor, stats it before and after the read,
// and refuses a file that changed underneath, that is not the metadata the catalog holds,
// that lies outside the authority of the root it came from, or whose body is empty or holds
// text a model cannot be shown. What it returns is owned by the allocator it was given and
// released with loaded_destroy, and it carries its own content digest.
//
// # Failures
//
// A procedure that can fail returns a Load_Error naming its kind, the line and field when
// the file is at fault, and a detail. Metadata, a loaded body, a catalog, and a Load_Error
// each own their strings and are released by their own destroy procedure, and the zero
// value of any of them owns nothing.
package skills
