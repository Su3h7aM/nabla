package term

// Operation-stream presentation (§6.8 of the frozen API target). This is the
// complete-target path alongside the full-frame `present`: the TUI plans a
// borrowed []Presentation_Op from current and previous logical buffers, and
// terminal validates, encodes, and transports it. Changed-line spans with one
// buffered write are the first optimization; scroll-region and cost-minimized
// cursor movement come only after measurement.
//
// The output path is caller-owned and reusable, with the same contract as the
// frame path: encoded_operations_size reports the exact required byte count,
// encode_operations returns written and repeats the exact required count, and
// a too-small scratch returns .Presentation_Workspace_Too_Small without
// writing a usable prefix. Operation text is borrowed and never retained, and
// terminal-control bytes cannot be supplied as an operation (grapheme
// validation is the same control-safety rule as the frame path).
//
// Serialization: Move_Cursor_Op emits CUP and suppresses a move to the
// already-tracked position (the tracked position starts unknown, so the first
// move always emits); Set_Style_Op emits one SGR group per change and the
// first one establishes the baseline with an unconditional reset;
// Write_Grapheme_Op writes the grapheme bytes verbatim; Erase_Cells_Op emits
// ECH, which erases without moving the cursor. The base SGR state is restored
// at the end of the stream, the same invariant the frame path keeps. The
// stream leaves the cursor where the last operation placed it — the planner
// positions the cursor explicitly, and a caller that needs a specific end
// position emits a trailing Move_Cursor_Op.
//
// A hard write failure may occur after a prefix has reached the terminal;
// terminal contents and cursor state are then unspecified. The caller
// recovers with a later successful full frame or by closing the session.

// Presentation_Op is one terminal operation. The union is terminal-owned
// (§13.7): tui plans ops, terminal validates, encodes, and transports them.
Presentation_Op :: union #no_nil {
	Move_Cursor_Op,
	Set_Style_Op,
	Write_Grapheme_Op,
	Erase_Cells_Op,
}

// Move_Cursor_Op positions the cursor; coordinates are zero-based and
// validated non-negative (an op stream carries no frame dimensions, so the
// planner owns placement against the viewport).
Move_Cursor_Op :: struct {
	position: Position,
}

// Set_Style_Op changes the presentation style for subsequent writes and
// erases. Colors are reduced deterministically to the profile depth at
// serialization time, exactly like the frame path.
Set_Style_Op :: struct {
	style: Presentation_Style,
}

// Write_Grapheme_Op writes one grapheme at the current cursor position,
// advancing the cursor by width cells. The grapheme is borrowed for the call
// and must be control-safe; v1 serializes width-1 graphemes only (width-0/1/2
// continuation cells are the complete target). An empty grapheme is a
// documented no-op, the same blank-cell rule as the frame path.
Write_Grapheme_Op :: struct {
	grapheme: string,
	width:    u8,
}

// Erase_Cells_Op erases count cells at the current cursor position with the
// current rendition (ECH), leaving the cursor in place. count == 0 serializes
// nothing.
Erase_Cells_Op :: struct {
	count: int,
}

@(require_results)
encoded_operations_size :: proc(operations: []Presentation_Op, profile: Target_Profile) -> (required: int, err: Error) {
	if v_err := _validate_operations(operations); v_err != nil {
		return 0, v_err
	}
	e := _Encoder {
		count_only = true,
	}
	_serialize_operations(&e, operations, profile.color_depth)
	return e.pos, nil
}

// encode_operations serializes the operation stream into caller-owned output.
// It returns written (the bytes to consume: output[:written]) and repeats the
// exact required count. A too-small scratch returns
// .Presentation_Workspace_Too_Small with written == 0 and nothing usable
// written; the caller resizes and retries, never guessing.
@(require_results)
encode_operations :: proc(operations: []Presentation_Op, profile: Target_Profile, output: []byte) -> (written: int, required: int, err: Error) {
	if v_err := _validate_operations(operations); v_err != nil {
		return 0, 0, v_err
	}
	e := _Encoder {
		count_only = true,
	}
	_serialize_operations(&e, operations, profile.color_depth)
	required = e.pos
	if required > len(output) {
		return 0, required, General_Error.Presentation_Workspace_Too_Small
	}
	w := _Encoder {
		out = output,
	}
	_serialize_operations(&w, operations, profile.color_depth)
	if w.overflowed {
		// Unreachable: the count pass just produced the exact size.
		return 0, required, General_Error.Presentation_Workspace_Too_Small
	}
	return w.pos, required, nil
}

// present_operations performs the same preflight as encode_operations and
// never touches the session when the scratch is too small; on success it
// writes the encoded stream as one buffered sequence and returns the number
// of bytes committed before any transport failure.
@(require_results)
present_operations :: proc(
	session: ^Session,
	operations: []Presentation_Op,
	profile: Target_Profile,
	output: []byte,
) -> (
	committed: int,
	required: int,
	err: Error,
) {
	if session == nil || !session.opened {
		return 0, 0, General_Error.Not_Open
	}
	if v_err := _validate_operations(operations); v_err != nil {
		return 0, 0, v_err
	}
	e := _Encoder {
		count_only = true,
	}
	_serialize_operations(&e, operations, profile.color_depth)
	required = e.pos
	if required > len(output) {
		return 0, required, General_Error.Presentation_Workspace_Too_Small
	}
	w := _Encoder {
		out = output,
	}
	_serialize_operations(&w, operations, profile.color_depth)
	if w.overflowed {
		return 0, required, General_Error.Presentation_Workspace_Too_Small
	}
	committed_bytes, write_err := _session_present(session, output[:required])
	return committed_bytes, required, write_err
}

// _validate_operations checks every operation before a single byte is
// serialized or written. An op stream carries no frame dimensions, so bounds
// are structural only: negative coordinates and counts are caller errors,
// width must be the v1 width-1 value, and a grapheme can never inject
// terminal control into the output stream.
_validate_operations :: proc(operations: []Presentation_Op) -> Error {
	for op in operations {
		switch o in op {
		case Move_Cursor_Op:
			if o.position.x < 0 || o.position.y < 0 {
				return General_Error.Invalid_Cursor
			}
		case Set_Style_Op:
		// Plain data; color reduction happens at serialization time.
		case Write_Grapheme_Op:
			if o.width != 1 {
				// v1 serializes width-1 graphemes only; width-0/1/2
				// continuation cells are the complete target.
				return General_Error.Unsupported
			}
			if len(o.grapheme) > 0 && !_grapheme_safe(o.grapheme) {
				return General_Error.Invalid_Cell
			}
		case Erase_Cells_Op:
			if o.count < 0 {
				return General_Error.Invalid_Frame_Data
			}
		}
	}
	return nil
}

// _serialize_operations renders the (validated) operation stream to ANSI
// bytes. The encoder tracks the cursor and the presentation style so it can
// suppress a move to the already-tracked position and emit one SGR group per
// style change; the tracked cursor starts unknown (a stream has no
// cross-frame state), so the first Move_Cursor_Op always emits CUP. Erases
// use ECH, which leaves the cursor in place. The base SGR state is restored
// at the end of the stream, the same invariant the frame path keeps.
_serialize_operations :: proc(e: ^_Encoder, operations: []Presentation_Op, depth: Color_Depth) {
	cursor_known := false
	cursor: Position
	style_known := false
	style: Presentation_Style

	for op in operations {
		switch o in op {
		case Move_Cursor_Op:
			if !cursor_known || cursor != o.position {
				// CUP is 1-based; the +1 runs in u64 so a max(int)
				// coordinate cannot overflow (max(int) + 1 == 2^63).
				_enc_str(e, "\e[")
				_enc_uint(e, u64(o.position.y) + 1)
				_enc_str(e, ";")
				_enc_uint(e, u64(o.position.x) + 1)
				_enc_str(e, "H")
				cursor = o.position
				cursor_known = true
			}
		case Set_Style_Op:
			if !style_known {
				// The terminal's current rendition is unknown at stream
				// start; the first style op establishes the baseline even
				// when the target is the base style.
				_enc_style_establish(e, o.style, depth)
				style = o.style
				style_known = true
			} else if style != o.style {
				_enc_style_diff(e, style, o.style, depth)
				style = o.style
			}
		case Write_Grapheme_Op:
			_enc_str(e, o.grapheme)
			if cursor_known && len(o.grapheme) > 0 {
				// Advance only when bytes were actually emitted: an empty
				// grapheme is a documented no-op and must not move the
				// tracked cursor — a phantom advance would suppress a later
				// move to the real position. The advance saturates at
				// max(int) (v1 width is always 1), keeping the tracked
				// cursor representable across the whole nonnegative domain.
				if cursor.x < max(int) {
					cursor.x += int(o.width)
				}
			}
		case Erase_Cells_Op:
			if o.count > 0 {
				_enc_str(e, "\e[")
				_enc_uint(e, u64(o.count))
				_enc_str(e, "X")
			}
		}
	}

	if style_known && style != (Presentation_Style{}) {
		// Restore the base SGR state at the end of the stream (baseline
		// contract).
		_enc_str(e, "\e[m")
	}
}
