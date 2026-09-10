package term

// Capability negotiation record (§6.5 of the frozen API target). These are
// the complete-target plain-data types: the caller-owned Capabilities record
// tracks what the session inferred, requested, confirmed, and ruled out, and
// plan_presentation's frozen signature consumes it.
//
// The session-backed negotiation procedures (request_capability,
// observe_capability, capabilities) are deferred to the capability milestone
// (D26); the target keeps them typed, and a v1 session has an all-empty
// Capabilities record. `inferred` records environment/terminfo assumptions
// and never proves support; `requested` records emitted requests; `confirmed`
// records a positive report; `unsupported` records a definitive negative
// report. A capability in none of the four sets is unknown. Synchronized
// output and Unicode Core are query-before-enable features: the mode must not
// be enabled until a confirmation is observed.

// Capability_Flag names one negotiable terminal feature. It deliberately
// begins with a real bit-set member (no `.None`), mirroring Modifier.
Capability_Flag :: enum u8 {
	Bracketed_Paste,
	Focus_Events,
	Mouse,
	Kitty_Keyboard,
	Synchronized_Output,
	Unicode_Core,
}

Capability_Flags :: distinct bit_set[Capability_Flag;u8]

// Capabilities is the plain-data session capability record. A zero value is
// the honest "nothing known yet" state.
Capabilities :: struct {
	inferred:    Capability_Flags,
	requested:   Capability_Flags,
	confirmed:   Capability_Flags,
	unsupported: Capability_Flags,
}

// Capability_Action selects what a request does. .None is the neutral zero
// value (a request that changes nothing).
Capability_Action :: enum u8 {
	None,
	Enable,
	Disable,
	Query,
}
