package term

import "base:runtime"
import "core:encoding/base64"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:terminal/ansi"

// Inline images use the Kitty graphics protocol with Unicode placeholders: an image is
// transmitted once under an Image_Id, placed in a run of cells, and appears wherever
// cells hold the placeholder with the id as their foreground color, as ordinary cell
// content that scrolls, clips, and is overwritten like text.

// Image_Id names a transmitted image as the 24-bit foreground color of its placeholder
// cells, so valid ids are 1 ..< IMAGE_ID_LIMIT; zero is no image.
Image_Id :: distinct u32

IMAGE_ID_LIMIT :: 1 << 24

Image_Format :: enum u8 {
	PNG, // a complete PNG file
	RGB, // width * height * 3 bytes, row-major
	RGBA, // width * height * 4 bytes, row-major
}

// Image is a borrowed image to transmit; width and height are pixels and serve the raw
// formats only, since a PNG carries its own size.
Image :: struct {
	data:   []byte,
	format: Image_Format,
	width:  int,
	height: int,
}

// GRAPHICS_PLACEHOLDER (U+10EEEE) marks a cell as part of an image. With no combining
// marks it inherits the row and the column after its left neighbor, so only the first
// cell of a row needs marks.
GRAPHICS_PLACEHOLDER :: "\U0010EEEE"

// GRAPHICS_MAX_COLUMNS and GRAPHICS_MAX_ROWS bound a placement in cells: the protocol numbers rows and columns with a 297-long list of combining marks.
GRAPHICS_MAX_ROWS :: len(graphics_placeholder_rows)
GRAPHICS_MAX_COLUMNS :: GRAPHICS_MAX_ROWS

// GRAPHICS_CHUNK_SIZE is the protocol's limit on one base64 payload chunk.
GRAPHICS_CHUNK_SIZE :: 4096

@(private = "file")
_COLUMN_ZERO_DIACRITIC :: "\u0305"

// graphics_placeholder_rows holds, per image row, the text of that row's first cell:
// the placeholder, the row's combining mark, and the column-0 mark; later cells are
// bare GRAPHICS_PLACEHOLDER. The strings are static.
@(rodata)
graphics_placeholder_rows := [?]string {
	GRAPHICS_PLACEHOLDER + "\u0305" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u030D" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u030E" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0310" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0312" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u033D" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u033E" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u033F" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0346" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u034A" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u034B" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u034C" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0350" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0351" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0352" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0357" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u035B" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0363" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0364" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0365" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0366" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0367" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0368" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0369" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u036A" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u036B" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u036C" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u036D" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u036E" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u036F" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0483" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0484" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0485" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0486" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0487" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0592" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0593" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0594" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0595" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0597" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0598" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0599" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u059C" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u059D" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u059E" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u059F" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u05A0" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u05A1" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u05A8" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u05A9" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u05AB" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u05AC" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u05AF" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u05C4" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0610" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0611" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0612" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0613" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0614" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0615" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0616" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0617" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0657" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0658" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0659" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u065A" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u065B" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u065D" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u065E" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u06D6" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u06D7" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u06D8" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u06D9" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u06DA" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u06DB" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u06DC" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u06DF" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u06E0" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u06E1" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u06E2" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u06E4" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u06E7" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u06E8" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u06EB" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u06EC" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0730" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0732" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0733" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0735" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0736" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u073A" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u073D" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u073F" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0740" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0741" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0743" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0745" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0747" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0749" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u074A" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u07EB" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u07EC" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u07ED" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u07EE" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u07EF" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u07F0" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u07F1" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u07F3" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0816" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0817" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0818" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0819" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u081B" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u081C" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u081D" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u081E" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u081F" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0820" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0821" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0822" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0823" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0825" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0826" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0827" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0829" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u082A" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u082B" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u082C" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u082D" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0951" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0953" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0954" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0F82" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0F83" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0F86" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u0F87" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u135D" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u135E" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u135F" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u17DD" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u193A" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1A17" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1A75" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1A76" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1A77" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1A78" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1A79" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1A7A" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1A7B" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1A7C" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1B6B" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1B6D" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1B6E" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1B6F" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1B70" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1B71" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1B72" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1B73" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1CD0" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1CD1" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1CD2" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1CDA" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1CDB" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1CE0" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1DC0" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1DC1" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1DC3" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1DC4" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1DC5" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1DC6" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1DC7" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1DC8" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1DC9" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1DCB" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1DCC" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1DD1" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1DD2" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1DD3" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1DD4" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1DD5" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1DD6" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1DD7" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1DD8" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1DD9" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1DDA" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1DDB" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1DDC" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1DDD" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1DDE" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1DDF" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1DE0" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1DE1" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1DE2" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1DE3" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1DE4" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1DE5" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1DE6" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u1DFE" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u20D0" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u20D1" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u20D4" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u20D5" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u20D6" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u20D7" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u20DB" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u20DC" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u20E1" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u20E7" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u20E9" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u20F0" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u2CEF" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u2CF0" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u2CF1" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u2DE0" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u2DE1" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u2DE2" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u2DE3" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u2DE4" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u2DE5" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u2DE6" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u2DE7" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u2DE8" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u2DE9" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u2DEA" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u2DEB" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u2DEC" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u2DED" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u2DEE" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u2DEF" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u2DF0" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u2DF1" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u2DF2" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u2DF3" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u2DF4" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u2DF5" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u2DF6" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u2DF7" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u2DF8" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u2DF9" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u2DFA" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u2DFB" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u2DFC" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u2DFD" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u2DFE" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\u2DFF" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\uA66F" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\uA67C" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\uA67D" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\uA6F0" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\uA6F1" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\uA8E0" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\uA8E1" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\uA8E2" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\uA8E3" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\uA8E4" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\uA8E5" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\uA8E6" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\uA8E7" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\uA8E8" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\uA8E9" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\uA8EA" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\uA8EB" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\uA8EC" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\uA8ED" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\uA8EE" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\uA8EF" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\uA8F0" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\uA8F1" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\uAAB0" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\uAAB2" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\uAAB3" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\uAAB7" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\uAAB8" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\uAABE" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\uAABF" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\uAAC1" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\uFE20" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\uFE21" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\uFE22" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\uFE23" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\uFE24" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\uFE25" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\uFE26" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\U00010A0F" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\U00010A38" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\U0001D185" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\U0001D186" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\U0001D187" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\U0001D188" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\U0001D189" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\U0001D1AA" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\U0001D1AB" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\U0001D1AC" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\U0001D1AD" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\U0001D242" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\U0001D243" + _COLUMN_ZERO_DIACRITIC,
	GRAPHICS_PLACEHOLDER + "\U0001D244" + _COLUMN_ZERO_DIACRITIC,
}

// graphics_detect reports whether the terminal is known to draw Kitty placeholder
// images, judged from the environment alone (the package has no query path): kitty and
// Ghostty at TrueColor depth (the id is a 24-bit color) outside tmux and screen, which
// swallow the graphics sequences. An unrecognized terminal reports false.
@(require_results)
graphics_detect :: proc(depth: Color_Depth) -> bool {
	term_buffer, program_buffer, scratch: [128]byte
	environment: _Graphics_Environment
	environment.term, _ = _env_value(term_buffer[:], "TERM")
	environment.term_program, _ = _env_value(program_buffer[:], "TERM_PROGRAM")
	_, environment.kitty_window = _env_value(scratch[:], "KITTY_WINDOW_ID")
	_, tmux := _env_value(scratch[:], "TMUX")
	_, screen := _env_value(scratch[:], "STY")
	environment.multiplexed = tmux || screen
	return _graphics_supported(depth, environment)
}

_Graphics_Environment :: struct {
	term:         string,
	term_program: string,
	kitty_window: bool,
	multiplexed:  bool,
}

_graphics_supported :: proc(depth: Color_Depth, environment: _Graphics_Environment) -> bool {
	if depth != .True_Color || environment.multiplexed {
		return false
	}
	return environment.kitty_window || environment.term == "xterm-kitty" || environment.term == "xterm-ghostty" || environment.term_program == "ghostty"
}

// _env_value returns the value of an environment variable in buf and whether it is set;
// a value too long for buf is set but matches no comparison. An empty value counts as
// unset: core:os's libc lookup reports a missing variable with no error, so the error
// alone cannot say.
_env_value :: proc(buf: []byte, key: string) -> (value: string, set: bool) {
	err: os.Error
	value, err = os.lookup_env(buf, key)
	return value, value != "" || err == io.Error.Buffer_Full
}

// graphics_transmit sends image under id and creates its placement, columns by rows
// cells, scaling the pixels to fit; an existing id is replaced. It returns the bytes
// written, and the terminal answers nothing, so a rejected image shows blank cells and
// the write still succeeds. Invalid ids or placements and malformed data return
// .Unsupported without writing; the sequence is one allocation with allocator, released
// before returning.
@(require_results)
graphics_transmit :: proc(session: ^Session, id: Image_Id, image: Image, columns, rows: int, allocator := context.allocator) -> (committed: int, err: Error) {
	if session == nil || !session.opened {
		return 0, General_Error.Not_Open
	}
	sequence := _graphics_transmit_sequence(id, image, columns, rows, allocator) or_return
	defer delete(sequence, allocator)
	return _session_present(session, transmute([]byte)sequence)
}

// graphics_place resizes the placement of a transmitted image to columns by rows cells,
// recreating it from the data the terminal kept; an id the terminal does not hold shows
// nothing. Errors and allocation are those of graphics_transmit.
@(require_results)
graphics_place :: proc(session: ^Session, id: Image_Id, columns, rows: int, allocator := context.allocator) -> (committed: int, err: Error) {
	if session == nil || !session.opened {
		return 0, General_Error.Not_Open
	}
	sequence := _graphics_place_sequence(id, columns, rows, allocator) or_return
	defer delete(sequence, allocator)
	return _session_present(session, transmute([]byte)sequence)
}

// graphics_delete deletes an image's placements and frees its data in the terminal;
// placeholder cells still drawn show nothing. Errors and allocation are those of
// graphics_transmit.
@(require_results)
graphics_delete :: proc(session: ^Session, id: Image_Id, allocator := context.allocator) -> (committed: int, err: Error) {
	if session == nil || !session.opened {
		return 0, General_Error.Not_Open
	}
	sequence := _graphics_delete_sequence(id, allocator) or_return
	defer delete(sequence, allocator)
	return _session_present(session, transmute([]byte)sequence)
}

// q=2 suppresses the terminal's replies, which nothing reads.
_GRAPHICS_START :: ansi.ESC + "_G"

@(require_results)
_graphics_transmit_sequence :: proc(id: Image_Id, image: Image, columns, rows: int, allocator: runtime.Allocator) -> (sequence: string, err: Error) {
	if !_graphics_valid(id, columns, rows) || len(image.data) == 0 {
		return "", General_Error.Unsupported
	}
	bytes_per_pixel := 3 if image.format == .RGB else 4
	if image.format != .PNG {
		pixels := len(image.data) / bytes_per_pixel
		if image.width <= 0 ||
		   image.height <= 0 ||
		   len(image.data) % bytes_per_pixel != 0 ||
		   image.width > pixels / image.height ||
		   image.width * image.height != pixels {
			return "", General_Error.Unsupported
		}
	}
	encoded := base64.encode(image.data, allocator = allocator) or_return
	defer delete(encoded, allocator)

	// One allocation holds the whole sequence: each chunk adds only a few bytes of framing.
	chunks := (len(encoded) + GRAPHICS_CHUNK_SIZE - 1) / GRAPHICS_CHUNK_SIZE
	builder := strings.builder_make_len_cap(0, len(encoded) + 256 + 16 * chunks, allocator) or_return
	for start := 0; start < len(encoded); start += GRAPHICS_CHUNK_SIZE {
		end := min(start + GRAPHICS_CHUNK_SIZE, len(encoded))
		strings.write_string(&builder, _GRAPHICS_START)
		if start == 0 {
			fmt.sbprintf(&builder, "a=T,U=1,q=2,i=%d,c=%d,r=%d,", u32(id), columns, rows)
			if image.format == .PNG {
				strings.write_string(&builder, "f=100,")
			} else {
				fmt.sbprintf(&builder, "f=%d,s=%d,v=%d,", 8 * bytes_per_pixel, image.width, image.height)
			}
		}
		strings.write_string(&builder, "m=1;" if end < len(encoded) else "m=0;")
		strings.write_string(&builder, encoded[start:end])
		strings.write_string(&builder, ansi.ST)
	}
	return strings.to_string(builder), nil
}

@(require_results)
_graphics_place_sequence :: proc(id: Image_Id, columns, rows: int, allocator: runtime.Allocator) -> (sequence: string, err: Error) {
	if !_graphics_valid(id, columns, rows) {
		return "", General_Error.Unsupported
	}
	// A placement without a placement id adds one instead of replacing, so the old placement goes first; the lowercase delete keeps the data.
	sequence = fmt.aprintf(
		_GRAPHICS_START + "a=d,d=i,i=%d,q=2" + ansi.ST + _GRAPHICS_START + "a=p,U=1,q=2,i=%d,c=%d,r=%d" + ansi.ST,
		u32(id),
		u32(id),
		columns,
		rows,
		allocator = allocator,
	)
	if sequence == "" {
		return "", runtime.Allocator_Error.Out_Of_Memory
	}
	return sequence, nil
}

@(require_results)
_graphics_delete_sequence :: proc(id: Image_Id, allocator: runtime.Allocator) -> (sequence: string, err: Error) {
	if !_graphics_valid(id, 1, 1) {
		return "", General_Error.Unsupported
	}
	sequence = fmt.aprintf(_GRAPHICS_START + "a=d,d=I,i=%d,q=2" + ansi.ST, u32(id), allocator = allocator)
	if sequence == "" {
		return "", runtime.Allocator_Error.Out_Of_Memory
	}
	return sequence, nil
}

_graphics_valid :: proc(id: Image_Id, columns, rows: int) -> bool {
	return 0 < id && id < IMAGE_ID_LIMIT && 0 < columns && columns <= GRAPHICS_MAX_COLUMNS && 0 < rows && rows <= GRAPHICS_MAX_ROWS
}
