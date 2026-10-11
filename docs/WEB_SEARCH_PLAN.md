# Native web search

The native `web_search` tool is implemented. This document records the finished design; `web_fetch` remains separate work.

## Packages

- `html/` is a standalone, non-allocating HTML tokenizer. Tokens and attributes borrow the input. It recognizes tags, text, comments, doctypes, and raw-text elements, but builds no tree, applies no implied end tags, and does not decode character references. It deliberately implements only part of HTML tokenization, not a browser parser.
- `web/` is a standalone client for web search services. It builds requests, decodes JSON or HTML at the boundary, and returns native `Result` values with `title`, `url`, `snippet`, and optional `published` text. `Response` also carries an optional synthesized answer and a count-clamping notice value. It has no tool, session, or harness configuration concept.
- `agent/tool_web_search.odin` owns the tool definition, arguments, execution, and human-facing reason. `agent/tool_output.odin` renders its typed output. `agent/config_web_search.odin` loads the provider configuration.

`web.search` calls one endpoint with caller-owned cancellation and deadline control through `http/client.Options`. Responses and error details belong to the caller's allocator and have matching destroy procedures. Error details contain static text plus numbers the package owns, never provider-supplied text or API keys.

`web.search_first` tries endpoints in order and returns the first success, including an empty result list. Its optional `first` argument moves that service's endpoints ahead of the others without changing their relative order. `web.engine` treats Exa REST and MCP as one service. Failures are recorded in order; `Cancelled` and `Timed_Out` stop fallback because the same caller control applies to every attempt.

## Provider requests

`base_url` replaces the default endpoint URL, except for SearXNG, where it names the required instance root and the client appends `/search`.

| Provider | Request and authentication | Count | Freshness | Domains | Results from |
| --- | --- | --- | --- | --- | --- |
| Brave | `GET https://api.search.brave.com/res/v1/web/search`, `q`, `count`, `freshness`; `X-Subscription-Token` | maximum 20 | `pd/pw/pm/py` | `site:` / `-site:` in `q` | `web.results[].title, url, description, age` |
| Tavily | `POST https://api.tavily.com/search`, bearer key; JSON `query`, `max_results`, `search_depth:"basic"`, `include_answer:"basic"`, `include_published_date:true`, `time_range`, `include_domains`, `exclude_domains` | maximum 20 | `day/week/month/year` | native | `results[].title, url, content, published_date`, plus `answer` |
| Exa REST | `POST https://api.exa.ai/search`, `x-api-key`; JSON `query`, `numResults`, `type:"auto"`, `contents:{highlights:true}`, `startPublishedDate`, `includeDomains`, `excludeDomains` | maximum 100 | RFC 3339 start date, now minus 1, 7, 30, or 365 days | native | `results[].title, url, publishedDate`, joined `highlights` or fallback `text` |
| Exa MCP | `POST https://mcp.exa.ai/mcp?tools=web_search_advanced_exa`, no key; JSON-RPC `tools/call` of `web_search_advanced_exa`, with `query`, `numResults`, `type:"auto"`, `enableHighlights:true`, `startPublishedDate`, `includeDomains`, `excludeDomains`; accepts JSON and event streams | maximum 100 | same as Exa REST | native | JSON search response in the first nonempty MCP text block, decoded like Exa REST |
| SearXNG | `GET {base_url}/search`, `q`, `format=json`, `time_range`; no key | instance page, keep at most requested count | `day/month/year`, week maps to month | `site:` / `-site:` in `q` | `results[].title, url, content, publishedDate` |
| DuckDuckGo HTML | `POST https://html.duckduckgo.com/html/`, form `q`, `df`; no key, browser `User-Agent`, HTML `Accept`, and `Referer` | one page, keep at most requested count | `df=d/w/m/y` | `site:` / `-site:` in `q` | result link and snippet classes, real URL from `uddg`, skipping ads |

Counts above a documented API maximum are lowered and reported in the tool's notice. DuckDuckGo bot challenges are `Rate_Limited`, not empty searches. Exa MCP replies may be bare JSON or SSE data messages; decoding matches the request id and reads JSON from the tool's text block, not `Title:` or `URL:` lines.

## Configuration

At configuration load, an absent `web_search`, `web_search = true`, or a table without `providers` builds the default endpoints with `web.endpoints_from_environment`. `ENVIRONMENT_VARIABLES` defines the detection order: Brave from `BRAVE_API_KEY`, Tavily from `TAVILY_API_KEY`, Exa REST from `EXA_API_KEY`, and SearXNG from `SEARXNG_URL`, each included only when its variable is nonempty. Keyless Exa MCP and DuckDuckGo always follow. `web_search = false` removes the tool.

A nonempty `providers` list sets the exact endpoint order and replaces the defaults. Entries accept `provider`, optional `api_key`, and optional `base_url`. `web.PROVIDER_NAMES` and `provider_parse` define the names `brave`, `tavily`, `exa`, `exa_mcp`, `searxng`, and `duckduckgo`; parsing ignores case.

```lua
web_search = {
    providers = {
        { provider = "searxng", base_url = "http://localhost:8888" },
        { provider = "brave", api_key = "${WORK_BRAVE_KEY}" },
    },
}
```

The loaded `Web_Search_Config` owns the endpoints and the deduplicated services in priority order for the process lifetime; sessions and tool definitions borrow it. Default selection happens at load, not on every search. At use, configured credential text is resolved through `config_resolve_credential`; an empty key or URL takes the provider's environment value. This does not add endpoints to the loaded list.

## Tool contract

`web_search` runs as a Worker on the native lane with an external network claim. It is read-only, non-destructive, non-idempotent, and open-world. Its default timeout is 30 seconds, with no harness maximum; `timeout_ms` overrides it. One interrupt and deadline probe covers all fallback attempts.

`query` is required and nonempty. Optional arguments are `count`, default 8; `freshness`, one of `any`, `day`, `week`, `month`, or `year`; `include_domains`; `exclude_domains`; `timeout_ms`; and `provider`. The model should put the year in queries about recent events because the search service does not know today's date.

The description, result text, and Lua output do not name services. The only service-specific model interface is the optional `provider` argument. Its schema enum lists the session's configured services in priority order, deduplicating Exa REST and MCP as `exa`. Selecting a service tries it first and retains the others as fallbacks.

Successful model text starts with `ok` and `results: <count>`, an optional `notice`, then an optional answer and numbered title, URL, published date, and snippet blocks. Zero results is success with advice to broaden the query. `Web_Search_Output` gives Lua the typed `notice`, `answer`, and `results`, with no provider or failure list.

The answering service, per-endpoint failures, HTTP status, retry delay, and missing-credential hints go only to `Tool_Result.reason`, the human-facing summary. They never enter the model text or Lua output. When every endpoint fails, model feedback is generic: trying again later may help if any failure was temporary, otherwise it is unlikely to help. Cancellation and timeout have their own outcomes and return no partial results.

## Left out

- Tavily still requires a key. Its keyless access header works but is undocumented, so the client does not send it.
- No cache, automatic retries, key pools, rate-limit coordinator, parallel fan-out, result fusion, or reranking. Ordered fallback handles endpoint failures; the model can repeat a search.
- Search hosted by a model provider is a separate API mechanism. If added, it belongs in `ai` request building rather than this standalone tool.
- No provider error text in package errors or model diagnostics. The caller gets classified failures without copying remote messages into trusted feedback.

## Completed phases

1. Done: standalone `html` tokenizer and tests.
2. Done: `web` core, JSON providers, environment discovery, and ordered fallback.
3. Done: DuckDuckGo HTML provider using `html`.
4. Done: native tool, configuration, provider preference, typed output, and tool tests.
5. Done: documentation of the finished design and architecture.

## Later: `web_fetch`

A separate `web_fetch` tool can retrieve a URL and return Markdown using the `html` tokenizer. HTML-to-Markdown conversion, content selection, and fetch-tool policy are not part of this search implementation.
