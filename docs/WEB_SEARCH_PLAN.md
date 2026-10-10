# Native web search: implementation plan

This plan replaces the Python-based `web-search` skill with a native `web_search` tool. It consolidates a study of eight reference projects (OpenCode `v2`, pi-web-access, ferris-search, mcp-web-search, agent-asearch, search-cli, websearch-mcpserver, ddgs) and fits the result to Nabla's architecture.

## 1. What the references agree on

Every reference, whatever its language or size, has the same core:

- One normalized result of three fields, `title`, `url`, `snippet`, sometimes with a published date. Every provider maps into it, and nothing downstream knows which provider answered.
- One small piece of code per provider: build the request, decode the response into the normalized result. No class hierarchy; a router switches on the provider name.
- A tool whose only required argument is `query`. Most add a result count; the richer ones add a recency filter and include/exclude domain lists. OpenCode `v2` has only `query`.
- A plain-text rendering for the model: one block per result with title, URL, optional date, and snippet. Zero results is a success with a short note, not an error.
- The same five providers recur: DuckDuckGo's HTML endpoint (no key), Brave, Tavily, Exa, and SearXNG (self-hosted, no key). Jina, Firecrawl, Serper, and Perplexity appear in some.

Where they differ, the difference is mostly over-engineering we should not copy: pi chains 37 providers with three overlapping selection mechanisms; search-cli fuses 13 providers with reciprocal-rank fusion and a disk cache; websearch-mcpserver has SQLite caching, rerankers, and key pools; OpenCode `v2` runs a consent form inside the tool and parses Exa results out of MCP text with regular expressions. Key pools, rate-limit coordinators, caches, rerankers, and fan-out to several providers per call all solve problems Nabla does not have.

Ideas worth keeping:

- OpenCode `v2`: the minimal model interface, the one result type, the rendering (`## [title](url)`, `Published:`, content), and treating 429 as the signal to move to another provider.
- pi-web-access: the full `SearchOptions` shape (`numResults`, `recencyFilter` day/week/month/year, `domainFilter`), folding domain filters into the query as `site:` and `-site:` for providers without native filters, and the split between bounded model text and full structured data for programmatic callers (our Lua `Tool_Output`).
- search-cli: failure categories with a `retryable` flag decided from the HTTP status, and keeping a provider's synthesized answer out of the result list.
- mcp-web-search and ddgs: DuckDuckGo `POST https://html.duckduckgo.com/html/` parsed by element class, with the real URL taken from the `uddg` query parameter and ad results skipped.

## 2. Design

### 2.1 Packages

A new library package `websearch` (library layer), describable without naming Nabla: "a client for web search APIs that returns normalized results". It imports `nabla:http/client`, `core:encoding/json`, `core:encoding/entity` (HTML entity decoding), and `core:net` (percent encoding). It carries no tool, session, or config concept.

A new library package `html` holding a small HTML tokenizer: start tags with attributes, end tags, text, comments, and raw text inside `script` and `style`. DuckDuckGo parsing needs it now, and a later `web_fetch` tool needs it for HTML to Markdown. A tokenizer is more robust than searching the page for class-name strings, which breaks on attribute order and quoting. It follows the shape of `core:encoding/xml`'s tokenizer.

The harness side lives in `agent`: `agent/tool_web_search.odin` (definition, arguments, execute, rendering) and the config loading in `agent/config.odin`.

### 2.2 Library types

```odin
package websearch

Provider :: enum {
	DuckDuckGo, // zero value: needs no key
	Brave,
	Tavily,
	Exa,
	SearXNG,
}

Freshness :: enum {
	Any,
	Day,
	Week,
	Month,
	Year,
}

// Query is one search. Strings and slices are borrowed for the call.
Query :: struct {
	text:            string,
	count:           int, // 0 means the provider's default
	freshness:       Freshness,
	include_domains: []string,
	exclude_domains: []string,
}

// Endpoint is one configured provider. api_key is "" for keyless providers.
// base_url replaces the provider's documented URL; SearXNG requires it.
Endpoint :: struct {
	provider: Provider,
	api_key:  string,
	base_url: string,
}

Result :: struct {
	title:     string,
	url:       string,
	snippet:   string,
	published: string, // as the provider wrote it; "" when absent
}

Response :: struct {
	results: []Result,
	answer:  string, // a provider's synthesized answer (Tavily), "" when none
}

Error_Kind :: enum {
	None,
	Missing_Credential, // the provider needs api_key or base_url
	Unauthorized,       // 401, 403
	Quota,              // 402, provider quota codes
	Rate_Limited,       // 429; retry_after when the response stated one
	Rejected,           // other 4xx
	Server,             // 5xx
	Transport,          // DNS, TLS, connection, framing
	Timed_Out,
	Cancelled,
	Invalid_Response,   // the body did not decode into results
}

Error :: struct {
	kind:        Error_Kind,
	status:      int,
	retry_after: time.Duration,
	detail:      string, // owned by the allocator passed to search
}

// search sends query to endpoint and returns the normalized results, allocated
// with allocator. options carries the caller's probe, so cancellation and the
// deadline belong to the caller.
search :: proc(endpoint: Endpoint, query: Query, options: client.Options, allocator := context.allocator) -> (response: Response, err: Error)

response_destroy :: proc(response: ^Response, allocator := context.allocator)
```

`search` switches on `endpoint.provider`; each provider is one file with two procedures, `brave_request(endpoint, query) -> client.Request` and `brave_decode(body) -> (Response, Error)`. JSON providers unmarshal into private wire structs that hold only the fields read (as `acp/protocol.odin` does with `json.unmarshal`), then copy into `Result`. JSON stays inside these files. The status-to-kind mapping is one procedure shared by every provider, and an error `detail` never contains the key.

### 2.3 Provider requests

| Provider | Request | Auth | Count | Freshness | Domains | Results from |
| --- | --- | --- | --- | --- | --- | --- |
| DuckDuckGo | `POST https://html.duckduckgo.com/html/`, form `q`, `df` | none; browser `User-Agent` | one page, about 10 | `df=d/w/m/y` | `site:` / `-site:` in `q` | `.result` not `.result--ad`: `a.result__a` text and `href` (real URL in `uddg`), `.result__snippet` text |
| Brave | `GET https://api.search.brave.com/res/v1/web/search?q&count&freshness` | `X-Subscription-Token` | max 20 | `pd/pw/pm/py` | `site:` / `-site:` in `q` | `web.results[].title, url, description, age` |
| Tavily | `POST https://api.tavily.com/search`, JSON `query, max_results, search_depth:"basic", time_range, include_domains, exclude_domains` | `Authorization: Bearer` | max 20 | `day/week/month/year` | native | `results[].title, url, content, published_date`; `answer` when asked |
| Exa | `POST https://api.exa.ai/search`, JSON `query, numResults, type:"auto", contents:{highlights:true}, startPublishedDate, includeDomains, excludeDomains` | `x-api-key` | max 100 | `startPublishedDate` = now minus period | native | `results[].title, url, highlights` (else `text`), `publishedDate` |
| SearXNG | `GET {base_url}/search?q&format=json&time_range` | none | page of the instance | `day/month/year` (week maps to month) | `site:` / `-site:` in `q` | `results[].title, url, content, publishedDate` |

Each provider's maximum count and freshness support come from its API documentation, so they are external limits (`docs/ARCHITECTURE.md` section 2.1). A requested count above a provider's maximum is sent as the maximum, and the result says so, as a reported repair.

### 2.4 Configuration

Search providers work the way model providers already do: with no configuration at all, every provider whose credential is in the environment is set up and used, and a provider that needs no key is always available.

- Detection: `BRAVE_API_KEY`, `TAVILY_API_KEY`, `EXA_API_KEY`, and `SEARXNG_URL` each enable their provider. Exa through its public MCP endpoint (`https://mcp.exa.ai/mcp`, JSON-RPC `tools/call` of `web_search_exa` over one HTTP POST, which OpenCode uses) and DuckDuckGo need no key and are always present.
- Default order, keyed providers first: Brave, Tavily, Exa (API), SearXNG, Exa (MCP), DuckDuckGo. A provider that fails for any reason other than `Cancelled` is recorded and the next one is tried; the first success ends the call.
- Configuration only overrides. A `web_search` Lua table can reorder the list, add a key under another name (`api_key = "${MY_KEY}"`, resolved at use through `config_resolve_credential`), set a `base_url`, or remove a provider; `web_search = false` removes the tool.

```lua
web_search = {
	providers = {
		{ provider = "searxng", base_url = "http://localhost:8888" },
		{ provider = "brave", api_key = "${WORK_BRAVE_KEY}" },
	},
}
```

`Provider` gains `Exa_MCP` beside `Exa`: one decodes the REST response, the other the MCP `tools/call` result, whose text blocks hold `Title:`, `URL:`, `Published:`, and `Text:` lines per result. Tavily's keyless header (`X-Tavily-Access-Mode: keyless`) is undocumented; it is tested against the live API before it is added, and left out if it is not a public mode.

### 2.5 The tool

- Name `web_search`, `Tool_Kind.Web_Search`, `Web_Search_Args` in `agent/tool_args.odin`, `Worker` placement, native lane, default timeout 30 seconds that the model may override.
- Hints: read-only yes, destructive no, idempotent no, open world yes.
- Arguments: `query` (required string), `count` (integer, default 8), `freshness` (`any`, `day`, `week`, `month`, `year`), `include_domains` and `exclude_domains` (string arrays), `timeout`.
- Execute builds a `client.Probe` from `ctx.control.interrupt` and the deadline, as `fetch_control_probe` in `agent/fetch.odin` does, so a stop or the timeout ends the request in any blocking phase.
- The description states what the tool returns, that it searches the configured providers in order, that the current date is not known to the provider (the model should put a year in the query for recent events), and the shape of the result.
- `Tool_Output` gets a `Web_Search_Output` variant holding the provider and the results, so a Lua caller reads typed values while the model reads the rendering.

Rendering, following section 14.3:

```text
ok
provider: brave
results: 3
failed: tavily: rate limited (HTTP 429, retry after 30s)

1. Bun v1.2 released
https://bun.sh/blog/bun-v1.2
published: 2025-01-22
Bun 1.2 adds ...

2. ...
```

- Zero results: `ok`, `results: 0`, and one line suggesting a broader query.
- Every provider failed: `error tool_failed: no provider returned results`, then one `failed:` line per provider with its kind, status, and detail. A missing credential names the config field and the environment variable it should reference.
- A cancelled or timed-out call is `Cancelled` or `Timed_Out` with no partial results.

### 2.6 What is left out, and why

- Hosted search by the model provider (Anthropic `web_search`, OpenAI `web_search`) runs on the provider's side as a different mechanism; it belongs to `ai` request building if we ever want it, not to this tool.
- No cache, retries, key pools, rate limiters, fan-out, or ranking. The ordered provider list covers failure, and the model can repeat a search.
- Hosted search by the model provider waits for provider authentication beyond API keys.

## 3. Phases

Each phase is one jj change, with `mise run fmt`, `mise run check`, and the tests of the touched packages before it closes.

1. **`html` tokenizer.** Package `html/`: `doc.odin`, a tokenizer returning tokens that borrow the input, and tests on real pages saved as test data. No tree building.
2. **`websearch` core and JSON providers.** `websearch/doc.odin`, `websearch.odin` (types, `search`, status mapping), `brave.odin`, `tavily.odin`, `exa.odin`, `searxng.odin`. Tests run `search` against a local HTTP listener through `base_url`, serving recorded responses, and check the normalized results and the error kinds for 401, 429 with `Retry-After`, 500, and a malformed body.
3. **DuckDuckGo provider.** `websearch/duckduckgo.odin` on the `html` tokenizer, with a recorded results page as test data, including an ad result and a `uddg` redirect.
4. **Tool and config.** `agent/tool_web_search.odin`, the `Tool_Kind`, `Tool_Args`, and `Tool_Output` additions, the `web_search` config table, the registry entry, and one tool-level test that runs a call against a local listener and checks the rendering and the provider fallback.
5. **Documentation.** Section 14 of `docs/ARCHITECTURE.md` (tool table and native tool notes), section 4 (package map), and the default timeout in section 27. Then retire the Python `web-search` skill in `~/.agents/skills/web-search`, or reduce it to guidance on writing queries.

Phases 1 and 2 touch disjoint files and can run in parallel. Phase 3 waits for both, and phase 4 waits for phase 2.

## 4. Later: `web_fetch`

A companion `web_fetch(url, timeout)` that returns a page as Markdown, built on the `html` tokenizer with a walker that keeps headings, paragraphs, lists, links, code, and tables and drops `script`, `style`, `nav`, and similar elements. Every reference that has a search tool also has one, and it replaces the `curl | html2text` half of the current skill. It is a separate plan once `web_search` is in.

## 5. Open questions

- The native lane serializes `web_search` with `read`, `shell`, and the other native tools. That matches how every native tool runs today; a lane of its own would let a slow search run beside file work, and would need a new `Tool_Lane` variant.
- Whether the model should see the list of configured providers in the description. It changes nothing the model can choose, so the plan leaves it out.
