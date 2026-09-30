#+build linux
#+private
package term

import "core:sys/linux"

// Termios mirrors the kernel's struct termios (asm-generic/termbits.h), the
// layout TCGETS and TCSETS* transfer. core:sys/linux has no termios type.
Termios :: struct {
	c_iflag: u32,
	c_oflag: u32,
	c_cflag: u32,
	c_lflag: u32,
	c_line:  u8,
	c_cc:    [TERMIOS_NCCS]u8,
}

TERMIOS_NCCS :: 19

// Request numbers from asm-generic/ioctls.h. TCSETSF is tcsetattr's
// TCSAFLUSH: apply after output drains and discard pending input.
TCGETS :: 0x5401
TCSETS :: 0x5402
TCSETSW :: 0x5403
TCSETSF :: 0x5404
TCSAFLUSH :: TCSETSF

// c_lflag bits.
ISIG :: 0o1
ICANON :: 0o2
ECHO :: 0o10
ECHONL :: 0o100
IEXTEN :: 0o100000

// c_iflag bits.
INLCR :: 0o100
IGNCR :: 0o200
ICRNL :: 0o400
IXON :: 0o2000

// c_oflag bits.
OPOST :: 0o1

// c_cc indices.
VTIME :: 5
VMIN :: 6

// MAX_ERRNO bounds the negated errnos ioctl returns at the top of the address
// space, as in the kernel's IS_ERR_VALUE.
MAX_ERRNO :: 4095

// _ioctl returns the errno decoded from linux.ioctl's raw result.
@(require_results)
_ioctl :: proc "contextless" (fd: linux.Fd, request: u32, arg: rawptr) -> linux.Errno {
	result := linux.ioctl(fd, request, uintptr(arg))
	if result > ~uintptr(0) - MAX_ERRNO {
		return linux.Errno(-int(result))
	}
	return .NONE
}

@(require_results)
_tcgetattr :: proc "contextless" (fd: linux.Fd, termios: ^Termios) -> linux.Errno {
	return _ioctl(fd, TCGETS, termios)
}

@(require_results)
_tcsetattr :: proc "contextless" (fd: linux.Fd, request: u32, termios: ^Termios) -> linux.Errno {
	return _ioctl(fd, request, termios)
}
