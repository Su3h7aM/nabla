package agent

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode"

import "nabla:http"
import "nabla:web"

TOOL_WEB_FETCH_NAME :: "web_fetch"

TOOL_WEB_FETCH_DESCRIPTION :: `Read a known HTTP or HTTPS URL; use web_search to discover sources. HTML becomes Markdown (default) or plain text; format "html" returns the raw page. Text and JSON pass through; binaries are refused. JavaScript is not run and browser challenges cannot be solved; search for another source if a page is empty or blocked. Large results show a preview and keep the full output in a file. The timeout defaults to 30 seconds; timeout_ms overrides it without a maximum.`

TOOL_WEB_FETCH_SCHEMA :: `{"type":"object","properties":{"url":{"type":"string","description":"An HTTP or HTTPS URL to fetch. A missing https:// is added."},"format":{"type":["string","null"],"enum":["markdown","text","html",null],"description":"Output format. Omit or pass null for Markdown; html returns the raw page only when explicitly requested."},"timeout_ms":{"type":["integer","null"],"description":"Positive timeout in milliseconds, with no maximum. Default: 30000."}},"required":["url"],"additionalProperties":false}`

TOOL_WEB_FETCH_FIELDS :: []string{"url", "format", "timeout_ms"}

// TOOL_WEB_FETCH_DEFAULT_TIMEOUT applies when the model gives no timeout. There is no maximum.
TOOL_WEB_FETCH_DEFAULT_TIMEOUT :: 30 * time.Second

TOOL_WEB_FETCH_DEFINITION :: Tool_Definition {
	name = TOOL_WEB_FETCH_NAME,
	description = TOOL_WEB_FETCH_DESCRIPTION,
	input_schema = TOOL_WEB_FETCH_SCHEMA,
	hints = {read_only = .Yes, destructive = .No, idempotent = .No, open_world = .Yes},
	timeout = TOOL_WEB_FETCH_DEFAULT_TIMEOUT,
	kind = .Web_Fetch,
	execute = tool_web_fetch_execute,
}

// tool_web_fetch_url reads the url argument. Surrounding whitespace and a missing scheme have one
// reading, so they are repaired: the document is rewritten with the corrected URL and the
// repair is reported with the result. Anything else wrong with the URL is refused.
@(private, require_results)
tool_web_fetch_url :: proc(ctx: ^Tool_Context, arguments: json.Object) -> (url: string, err: Tool_Argument_Error) {
	original := tool_field_string(arguments, "url", allocator = ctx.allocator) or_return
	trimmed := strings.trim_space(original)
	if trimmed == "" { return "", tool_argument_error(.Invalid_Value, "url", "a non-empty absolute HTTP or HTTPS URL", ctx.allocator) }
	for character in trimmed {
		if character < 0x20 || character == 0x7f {
			return "", tool_argument_error(.Invalid_Value, "url", "a URL without control characters", ctx.allocator)
		}
		if unicode.is_space(character) {
			return "", tool_argument_error(.Invalid_Value, "url", "a URL without spaces; percent-encode a space as %20", ctx.allocator)
		}
	}
	repairs: Tool_Repairs
	if trimmed != original { repairs += {.Text_Trimmed} }
	candidate := trimmed
	has_http_scheme := len(trimmed) >= 7 && strings.equal_fold(trimmed[:7], "http://") || len(trimmed) >= 8 && strings.equal_fold(trimmed[:8], "https://")
	has_authority_prefix := strings.has_prefix(trimmed, "//")
	if !has_http_scheme && !has_authority_prefix {
		authority := tool_web_url_authority(trimmed)
		// Prefer a valid host:port as a convenience: RFC 3986 alone cannot distinguish localhost:3000 from a scheme named localhost.
		if !tool_web_url_authority_valid(authority) {
			if scheme := tool_web_url_scheme(trimmed); scheme != "" {
				return "", tool_argument_error(
					.Invalid_Value,
					"url",
					fmt.tprintf("a correctly formed HTTP or HTTPS URL; scheme %q cannot be fetched in this form", scheme),
					ctx.allocator,
				)
			}
			return "", tool_argument_error(
				.Invalid_Value,
				"url",
				"a valid hostname or bracketed IPv6 address, with an optional decimal port from 1 to 65535",
				ctx.allocator,
			)
		}
	}
	if !has_http_scheme {

		prefix := "https:" if strings.has_prefix(trimmed, "//") else "https://"
		built, build_error := strings.concatenate({prefix, trimmed}, ctx.allocator)
		if build_error != nil { return "", Tool_Argument_Defect{kind = .Out_Of_Memory} }
		candidate = built
		repairs += {.Url_Scheme_Added}
	}
	owned := candidate != trimmed
	defer if owned { delete(candidate, ctx.allocator) }
	parsed := http.url_parse(candidate)
	if !strings.equal_fold(parsed.scheme, "http") && !strings.equal_fold(parsed.scheme, "https") {
		return "", tool_argument_error(.Invalid_Value, "url", "an HTTP or HTTPS URL; other schemes cannot be fetched", ctx.allocator)
	}
	if strings.contains(parsed.host, "@") {
		return "", tool_argument_error(.Invalid_Value, "url", "a URL without a username or password before the host", ctx.allocator)
	}
	if !tool_web_url_authority_valid(parsed.host) {
		return "", tool_argument_error(
			.Invalid_Value,
			"url",
			"a valid hostname or bracketed IPv6 address, with an optional decimal port from 1 to 65535",
			ctx.allocator,
		)
	}

	if repairs == {} { return original, nil }
	if !owned {
		cloned, clone_error := strings.clone(candidate, ctx.allocator)
		if clone_error != nil { return "", Tool_Argument_Defect{kind = .Out_Of_Memory} }
		candidate = cloned
	}
	owned = false
	object := arguments
	slot := &object["url"]
	json.destroy_value(slot^, ctx.allocator)
	slot^ = json.String(candidate)
	ctx.repairs += repairs
	return candidate, nil
}

@(private)
tool_web_url_scheme :: proc(text: string) -> string {
	end := strings.index_byte(text, ':')
	if end <= 0 { return "" }
	for character, index in text[:end] {
		letter := character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z'
		if !letter && (index == 0 || !(character >= '0' && character <= '9' || character == '+' || character == '-' || character == '.')) { return "" }
	}
	return text[:end]
}

@(private)
tool_web_url_authority :: proc(text: string) -> string {
	for character, index in text {
		if character == '/' || character == '?' || character == '#' { return text[:index] }
	}
	return text
}

@(private)
tool_web_url_authority_valid :: proc(authority: string) -> bool {
	if authority == "" { return false }
	port_text: string
	if authority[0] == '[' {
		closing := strings.index_byte(authority, ']')
		if closing <= 1 { return false }
		_, valid := net.parse_ip6_address(authority[1:closing])
		if !valid { return false }
		if closing == len(authority) - 1 { return true }
		if authority[closing + 1] != ':' { return false }
		port_text = authority[closing + 2:]
	} else {
		host, separator, port := strings.partition(authority, ":")
		if host == "" { return false }
		for character in host {
			if unicode.is_alpha(character) || unicode.is_digit(character) { continue }
			if character != '-' && character != '.' && character != '_' { return false }
		}
		if separator == "" { return true }
		port_text = port
	}
	if port_text == "" { return false }
	for character in port_text {
		if character < '0' || character > '9' { return false }
	}
	port, valid := strconv.parse_uint(port_text, 10)
	return valid && port > 0 && port <= uint(max(u16))
}

@(require_results)
tool_web_fetch_args :: proc(ctx: ^Tool_Context, arguments: json.Object) -> (args: Web_Fetch_Args, err: Tool_Argument_Error) {
	tool_fields_known(arguments, TOOL_WEB_FETCH_FIELDS, allocator = ctx.allocator) or_return
	args.url = tool_web_fetch_url(ctx, arguments) or_return
	format := "markdown"
	if value, present := arguments["format"]; present {
		if _, is_null := value.(json.Null); !is_null {
			format = tool_field_string(arguments, "format", allocator = ctx.allocator) or_return
		}
	}
	switch format {
	case "markdown":
		args.format = .Markdown
	case "text":
		args.format = .Text
	case "html":
		args.format = .HTML
	case:
		return {}, tool_argument_error(.Invalid_Value, "format", "markdown, text, or html", ctx.allocator)
	}
	args.timeout = tool_web_timeout(ctx, arguments) or_return
	return
}

@(require_results)
tool_web_fetch_execute :: proc(ctx: ^Tool_Context, arguments: Tool_Args) -> Tool_Result {
	args := arguments.(Web_Fetch_Args)
	control := tool_web_control(ctx.control, args.timeout)
	options := tool_web_options(&control)
	page, failure := web.fetch(args.url, args.format, options, ctx.allocator)
	defer web.error_destroy(&failure, ctx.allocator)
	if failure.kind != .None {
		return tool_web_failure_result(ctx, TOOL_WEB_FETCH_NAME, failure, true, tool_web_failure_cause(failure))
	}
	defer web.page_destroy(&page, ctx.allocator)
	output := Web_Fetch_Output {
		url          = page.url,
		redirected   = page.url != args.url,
		title        = page.title,
		description  = page.description,
		content_type = page.content_type,
		content      = page.content,
	}
	media_type, _, _ := strings.partition(page.content_type, ";")
	media_type = strings.trim_space(media_type)
	is_html := strings.equal_fold(media_type, "text/html") || strings.equal_fold(media_type, "application/xhtml+xml")
	if is_html && args.format != .HTML && strings.trim_space(page.content) == "" {
		return tool_result_of(
			ctx,
			.Tool_Failed,
			`web_fetch failed: the initial HTML has no readable text. The page probably builds its content with JavaScript, needs a login, or blocked the request. Search for another source, or fetch with format "html" to inspect the raw page.`,
			output,
			"no readable text",
		)
	}
	return tool_result_success(ctx, output, page.title)
}
