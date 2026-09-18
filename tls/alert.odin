package tls

// Alert_Level is how badly a peer objected (RFC 8446 section B.2).
Alert_Level :: enum u8 {
	Warning = 1,
	Fatal   = 2,
}

// Alert_Description is why a peer closed or refused. The ones a TLS 1.3 peer may
// send are listed; the rest of the space is unused.
Alert_Description :: enum u8 {
	Close_Notify                    = 0,
	Unexpected_Message              = 10,
	Bad_Record_Mac                  = 20,
	Record_Overflow                 = 22,
	Handshake_Failure               = 40,
	Bad_Certificate                 = 42,
	Unsupported_Certificate         = 43,
	Certificate_Revoked             = 44,
	Certificate_Expired             = 45,
	Certificate_Unknown             = 46,
	Illegal_Parameter               = 47,
	Unknown_Ca                      = 48,
	Access_Denied                   = 49,
	Decode_Error                    = 50,
	Decrypt_Error                   = 51,
	Protocol_Version                = 70,
	Internal_Error                  = 80,
	Missing_Extension               = 109,
	Unsupported_Extension           = 110,
	Unrecognized_Name               = 112,
	Bad_Certificate_Status_Response = 113,
	No_Application_Protocol         = 120,
}
