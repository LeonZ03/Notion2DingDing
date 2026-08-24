package protocol

import "encoding/json"

const Version = 1

type Request struct {
	ProtocolVersion int             `json:"protocolVersion"`
	RequestID       string          `json:"requestId"`
	Method          string          `json:"method"`
	Params          json.RawMessage `json:"params"`
}

type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type Response struct {
	ProtocolVersion int    `json:"protocolVersion"`
	RequestID       string `json:"requestId"`
	OK              bool   `json:"ok"`
	Result          any    `json:"result,omitempty"`
	Error           *Error `json:"error,omitempty"`
}

func Failure(requestID, code, message string) Response {
	return Response{
		ProtocolVersion: Version,
		RequestID:       requestID,
		OK:              false,
		Error: &Error{
			Code:    code,
			Message: message,
		},
	}
}
