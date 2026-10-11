#+test
package web

import "core:testing"

MARKDOWN_PAGE :: #load("testdata/page.html", string)

@(test)
test_html_to_markdown_page :: proc(t: ^testing.T) {
	title, content, err := html_to_markdown(MARKDOWN_PAGE, "https://example.org/docs/page.html", false)
	defer delete(title)
	defer delete(content)
	if !testing.expect(t, err == nil) { return }
	testing.expect_value(t, title, "Field & Guide")
	description, description_err := html_description(MARKDOWN_PAGE)
	defer delete(description)
	testing.expect(t, description_err == nil)
	testing.expect_value(t, description, "A field & trail guide.")
	metadata_cases := []struct {
		source, expected: string,
	} {
		{`<meta property="og:description" content=" Open &amp;  graph ">`, "Open & graph"},
		{`<meta name="description" content=""><meta property="og:description" content="Fallback">`, ""},
		{`<title>No description</title>`, ""},
	}
	for metadata_case in metadata_cases {
		value, metadata_err := html_description(metadata_case.source)
		testing.expect(t, metadata_err == nil)
		testing.expect_value(t, value, metadata_case.expected)
		delete(value)
	}

	expected :=
		`# Field & Guide

Read **carefully**, *please*. Visit [the guide](https://example.org/guide?q=1&x=2) or stay here.

- First
    - Nested
- Second

3. Third
4. Fourth

![Trail & map](https://example.org/images/map.png)

` +
		"```odin\nvalue := \"`\";\n```" +
		`

| Name | Value |
| --- | --- |
| Rock \| stone | A & *B* |

Done now.`
	testing.expect_value(t, content, expected)
	plain_title, plain, plain_err := html_to_markdown(MARKDOWN_PAGE, "https://example.org/docs/page.html", true)
	defer delete(plain_title)
	defer delete(plain)
	if !testing.expect(t, plain_err == nil) { return }
	testing.expect_value(t, plain_title, title)
	testing.expect_value(
		t,
		plain,
		`Field & Guide

Read carefully, please. Visit the guide or stay here.

First
Nested
Second

Third
Fourth

Trail & map

` +
		"value := \"`\";" +
		`

Name Value
Rock | stone A & B

Done now.`,
	)
}

@(test)
test_html_to_markdown_incomplete :: proc(t: ^testing.T) {
	page := `<body><main><h2>Title</h2><p>One<p>Two<ul><li>A<li>B</ul></missing><table><tr><td>X<td>Y<tr><td>Z</table><pre>last`
	for end in 0 ..= len(page) {
		title, content, err := html_to_markdown(page[:end], "https://example.org/", false)
		if !testing.expect(t, err == nil) { delete(title); delete(content); return }
		delete(title)
		delete(content)
	}
	title, content, err := html_to_markdown(`<main><p>One<p>Two<ul><li>A<li>B</ul></stray></main>`, "", false)
	defer delete(title)
	defer delete(content)
	testing.expect(t, err == nil)
	testing.expect_value(t, content, "One\n\nTwo\n\n- A\n- B")
}

@(test)
test_html_to_markdown_structures :: proc(t: ^testing.T) {
	Case :: struct {
		source, expected: string,
	}
	cases := []Case {
		{
			`<div role="main"><blockquote>Quote<br>Again</blockquote><p><code>a` +
			"`" +
			`b</code> <del>old</del></p><dl><dt>Term<dd>Definition</dl><hr></div><main>Second</main>`,
			"> Quote\n> Again\n\n``a`b`` ~~old~~\n\nTerm\nDefinition\n\n---",
		},
		{`<table><tr><td colspan="2">A | B</td></tr><tr><td>C</td><td>D</td></tr></table>`, "A \\| B\nC | D"},
		{`<body>Outside<article>Kept</article>Outside</body>`, "Kept"},
		{`<body><p># title</p><p>1. item</p><p>&amp;lt; *literal*</p></body>`, "\\# title\n\n1\\. item\n\n\\&lt; \\*literal\\*"},
		{`<p>#hashtag &lt;span&gt; ~~literal~~</p>`, "#hashtag \\<span> \\~\\~literal\\~\\~"},
		{
			`<p>19.3.0 • Public</p><p>12) item</p><p>1234567890. x</p><p>1.</p><ul><li>2. x</li></ul><ol><li>a<li>b<li>c</ol>`,
			"19.3.0 • Public\n\n12\\) item\n\n1234567890. x\n\n1\\.\n\n- 2\\. x\n\n1. a\n2. b\n3. c",
		},
		{`<p>--flag and snake_case</p><p>---</p><p>= x</p><p>+ x</p><p>a-b</p>`, "--flag and snake_case\n\n\\---\n\n= x\n\n\\+ x\n\na-b"},
		{"<p>---\n</p>", "\\---"},
		{"<p>Title<br>===\n</p>", "Title\n\\==="},
		{"<pre>\nline1<br>line2</pre>", "```\nline1\nline2\n```"},
		{`<body><div id="root"></div><noscript><p>Enable <b>JS</b></p></noscript></body>`, "Enable **JS**"},
		{`<main></main><p>Outside main</p><noscript><p>Hidden</p></noscript>`, "Outside main\n\nHidden"},
		{`<p>Real</p><noscript>Please enable scripts</noscript>`, "Real"},
	}
	for test_case in cases {
		title, content, err := html_to_markdown(test_case.source, "https://example.org/", false)
		testing.expect(t, err == nil)
		testing.expect_value(t, content, test_case.expected)
		delete(title)
		delete(content)
	}
}
@(test)
test_html_to_markdown_literal_text_and_containers :: proc(t: ^testing.T) {
	Case :: struct {
		source, markdown, plain: string,
	}
	cases := []Case {
		{
			`<p>&amp;lt;</p><p><a href="/&amp;lt;">Link</a></p><p><code>&amp;lt;</code></p>`,
			"\\&lt;\n\n[Link](https://example.org/\\&lt;)\n\n`&lt;`",
			"&lt;\n\nLink\n\n&lt;",
		},
		{
			`<p>## title</p><p>#<!--split--># title</p><p>#<span>#</span> title</p><p>####### title</p>`,
			"\\## title\n\n\\## title\n\n\\## title\n\n####### title",
			"## title\n\n## title\n\n## title\n\n####### title",
		},
		{
			`<blockquote><strong>Quote</strong></blockquote><blockquote><a href="/">Link</a></blockquote><blockquote><code>Code</code></blockquote>`,
			"> **Quote**\n\n> [Link](https://example.org/)\n\n> `Code`",
			"Quote\n\nLink\n\nCode",
		},
		{
			`<ul><li><p>First</p><p>Second</p></li></ul><ol start="10"><li><p>Third</p><p>Fourth</p></li></ol>`,
			"- First\n\n  Second\n\n10. Third\n\n    Fourth",
			"First\n\nSecond\n\nThird\n\nFourth",
		},
		{"<pre class=\"language-bad`token\"><code>value</code></pre>", "```\nvalue\n```", "value"},
		{
			`<ul><li><code>\a</code> - bell (BEL)</li><li><strong>Text</strong> - more</li></ul>`,
			"- `\\a` - bell (BEL)\n- **Text** - more",
			"\\a - bell (BEL)\nText - more",
		},
		{
			`<p>A &amp; B &amp;unknown; &amp;amp; &amp;#123; &amp;#x1F;</p><p><a href="/image.png?utm_source=x&amp;utm_campaign=y">Image</a></p>`,
			"A & B &unknown; \\&amp; \\&#123; \\&#x1F;\n\n[Image](https://example.org/image.png?utm_source=x&utm_campaign=y)",
			"A & B &unknown; &amp; &#123; &#x1F;\n\nImage",
		},
		{
			`<body class="cookie"><main id="main-menu"><header><h1>Article</h1><div class="vector-dropdown"><div class="vector-dropdown-content"><div class="vector-menu-content"><ul><li class="interlanguage-link"><a href="/fr">French</a></li><li class="interlanguage-link"><a href="/es">Spanish</a></li></ul></div></div></div></header><p>Body</p><div id="article_toc">Contents</div><p class="article NAV links">Navigation</p><p class="socialism">Socialism stays.</p></main></body>`,
			"# Article\n\nBody\n\nSocialism stays.",
			"Article\n\nBody\n\nSocialism stays.",
		},
		{`<body class="menu"><p>Body</p></body>`, "Body", "Body"},
		{`<body>Outside<article class="social"><p>Article</p></article></body>`, "Article", "Article"},
		{`<p>A <img alt="" src="/decorative.png"> B <img src="/unknown.png"></p>`, "A B ![](https://example.org/unknown.png)", "A B"},
		{`<p><img src="data:image/png;base64,aA==" alt="Map &amp; guide"><img src="data:image/png;base64,bA=="></p>`, "Map & guide", "Map & guide"},
		{`<img src="d&#97;ta:image/png;base64,aA==" alt="Data">`, "Data", "Data"},
		{`<p>Before <a href="https://x.com/"> </a><a href="https://medium.com/"><strong></strong></a> after.</p>`, "Before after.", "Before after."},
		{`<a href="/target"><img src="/logo.png" alt="Logo"></a>`, "[![Logo](https://example.org/logo.png)](https://example.org/target)", "Logo"},
		{`<a href="/target"><img src="/unknown.png"></a>`, "[![](https://example.org/unknown.png)](https://example.org/target)", ""},
		{`<a href="/target"><img src="data:image/png;base64,aA==" alt="Logo"></a>`, "[Logo](https://example.org/target)", "Logo"},
		{`<a href="/target"><img src="data:image/png;base64,aA=="></a>`, "", ""},
		{
			`<h2>Intro<a href="#intro">#</a><a href="/#intro">¶</a><a href="https://example.org/#intro">§</a><a href="#intro">🔗</a><a href="#intro"><span hidden>Anchor</span></a></h2>`,
			"## Intro",
			"Intro",
		},
		{
			`<h2>Intro <a href="/other#intro">#</a> <a href="#intro">details</a></h2>`,
			"## Intro [#](https://example.org/other#intro) [details](https://example.org/#intro)",
			"Intro # details",
		},
		{`<p><a href="#intro">#</a></p>`, "[#](https://example.org/#intro)", "#"},
		{`<h2><a href="#sum">∑</a></h2>`, "## [∑](https://example.org/#sum)", "∑"},
	}
	for test_case in cases {
		for plain_text in ([]bool{false, true}) {
			title, content, err := html_to_markdown(test_case.source, "https://example.org/", plain_text)
			testing.expect(t, err == nil)
			expected := test_case.markdown
			if plain_text { expected = test_case.plain }
			testing.expect_value(t, content, expected)
			delete(title)
			delete(content)
		}
	}
}
