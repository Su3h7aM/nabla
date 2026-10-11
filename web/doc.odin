// Package web is a client for web search APIs that returns normalized
// results. One call, search, sends a Query to one configured Endpoint and
// returns a Response of titles, URLs, snippets, and publication dates, whatever
// the provider is; nothing downstream needs to know which one answered.
//
// The providers are DuckDuckGo (its HTML results page, no key), Brave, Tavily,
// Exa (the REST API and the keyless MCP endpoint), and SearXNG. Each is one file with a request builder and a decoder
// for the provider's response. JSON stays inside those files: the decoders
// unmarshal into private structs that hold only the fields read, and the exported
// types are plain data. A provider's synthesized answer is kept in
// Response.answer, apart from the result list.
//
// A count above a provider's documented maximum is sent as the maximum, and the
// Response says so in count_clamped_to. A domain filter a provider cannot express
// natively is folded into the query text as site: terms, and a freshness it cannot
// express is left out.
//
// Every failure is an Error whose kind is decided from the HTTP status, so a
// caller can choose between waiting (Rate_Limited with retry_after), trying
// another provider (Quota, Server), and fixing its configuration
// (Missing_Credential, Unauthorized). search never retries.
//
// search_first tries an ordered list of endpoints until one answers and reports
// the failures before it. endpoints_from_environment builds the default list from
// BRAVE_API_KEY, TAVILY_API_KEY, EXA_API_KEY, and SEARXNG_URL, followed by the
// keyless providers. PROVIDER_NAMES and provider_parse give providers text names.
//
// Requests go through the http/client package. The caller owns cancellation and
// the deadline through client.Options.probe, and its other options apply as they
// do for any request; search sets Options.response_head for its own use. An Error
// detail never contains the API key. search holds no state, so several threads
// may call it at once.
package web
