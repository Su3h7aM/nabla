package http

import "core:path/filepath"

MIME_Type :: enum {
	Plain,
	Css,
	Csv,
	Gif,
	Html,
	Ico,
	Jpeg,
	Js,
	Json,
	Png,
	Svg,
	Url_Encoded,
	Xml,
	Zip,
	Wasm,
}

mime_from_extension :: proc(path: string) -> MIME_Type {
	//odinfmt:disable
	switch filepath.ext(path) {
	case ".html": return .Html
	case ".js":   return .Js
	case ".css":  return .Css
	case ".csv":  return .Csv
	case ".xml":  return .Xml
	case ".zip":  return .Zip
	case ".json": return .Json
	case ".ico":  return .Ico
	case ".gif":  return .Gif
	case ".jpeg": return .Jpeg
	case ".png":  return .Png
	case ".svg":  return .Svg
	case ".wasm": return .Wasm
	case:         return .Plain
	}
	//odinfmt:enable
}

@(private = "file")
_mime_to_content_type := [MIME_Type]string {
	.Plain       = "text/plain",
	.Css         = "text/css",
	.Csv         = "text/csv",
	.Gif         = "image/gif",
	.Html        = "text/html",
	.Ico         = "application/vnd.microsoft.ico",
	.Jpeg        = "image/jpeg",
	.Js          = "application/javascript",
	.Json        = "application/json",
	.Png         = "image/png",
	.Svg         = "image/svg+xml",
	.Url_Encoded = "application/x-www-form-urlencoded",
	.Xml         = "text/xml",
	.Zip         = "application/zip",
	.Wasm        = "application/wasm",
}

mime_to_content_type :: proc(mime: MIME_Type) -> string {
	return _mime_to_content_type[mime]
}
