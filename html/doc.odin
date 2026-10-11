// Package html is a small HTML tokenizer: it splits a document into start tags,
// end tags, text, comments, and doctypes. It builds no tree, applies no implied
// end tags, and knows nothing about which elements nest. It is a library for
// extracting data from pages and converting them, not a browser parser.
//
// The tokenizer follows the WHATWG HTML Standard's tokenization stage where that
// is cheap. Text runs until the next '<' that starts markup, so a '<' followed
// by a space or a digit stays text. Inside script, style, xmp, iframe, noembed,
// and noframes the content is raw text, and inside textarea and title it is
// escapable raw text: either way it is one text token that ends at the matching
// end tag, and '<' inside it is not markup. Everything after a plaintext start
// tag is text. A comment ends at "-->" or "--!>". A '<!' that is not a comment
// or a doctype, a '<?', and a "</" followed by a non-letter are comments that
// run to the next '>'. A "</>" is dropped.
//
// It is deliberately limited. It does not implement the script data escaped
// states, so "<!--<script>" inside a script does not change where the script
// ends. A doctype ends at the first '>', even inside a quoted identifier. A tag
// cut off by the end of the input is returned as a token, where the standard
// drops it. It does not track the noscript scripting flag and treats noscript as
// an ordinary element. Nothing here validates the document.
//
// Malformed input never fails. Unterminated tags, comments, quoted attribute
// values, and raw text end at the end of the input, and the tokenizer returns
// what it has read up to there as a token.
//
// Tokens borrow the input string and nothing allocates. The input must outlive
// every token and attribute taken from it. A start tag token carries its
// attributes as unparsed text; next_attribute walks them and attribute looks one
// up by name, both without allocating.
//
// Tag names, attribute names, and the raw text element names are matched ASCII
// case-insensitively, but the tokens return them as written. Callers compare
// them with name_equal, which compares bytes only; strings.equal_fold folds
// Unicode and would match "claſs" to "class". Text, comments, and attribute
// values are returned raw. Character references such as "&amp;" and "&#x27;"
// are not decoded here; callers decode them with core:encoding/entity.
//
// A Tokenizer is used by one thread at a time and holds no lock.
package html
