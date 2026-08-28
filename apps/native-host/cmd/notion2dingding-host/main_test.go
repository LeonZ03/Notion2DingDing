package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"testing"

	"github.com/LeonZ03/Notion2DingDing/apps/native-host/internal/protocol"
)

type fakeHandler struct{}

func (fakeHandler) Handle(request protocol.Request) protocol.Response {
	return protocol.Response{
		ProtocolVersion: protocol.Version,
		RequestID:       request.RequestID,
		OK:              true,
		Result:          map[string]any{"received": true},
	}
}

func TestProcessMessageUsesNativeFraming(t *testing.T) {
	request := protocol.Request{
		ProtocolVersion: protocol.Version,
		RequestID:       "framed-request",
		Method:          "health.check",
		Params:          json.RawMessage(`{}`),
	}
	payload, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	var input bytes.Buffer
	if err := binary.Write(&input, binary.LittleEndian, uint32(len(payload))); err != nil {
		t.Fatal(err)
	}
	input.Write(payload)

	var output bytes.Buffer
	if err := processMessage(&input, &output, fakeHandler{}); err != nil {
		t.Fatalf("processMessage failed: %v", err)
	}
	var responseLength uint32
	if err := binary.Read(&output, binary.LittleEndian, &responseLength); err != nil {
		t.Fatal(err)
	}
	responsePayload := make([]byte, responseLength)
	if _, err := output.Read(responsePayload); err != nil {
		t.Fatal(err)
	}
	var response protocol.Response
	if err := json.Unmarshal(responsePayload, &response); err != nil {
		t.Fatal(err)
	}
	if !response.OK || response.RequestID != "framed-request" {
		t.Fatalf("unexpected response: %#v", response)
	}
}

func TestProcessMessageRejectsOversizedFrame(t *testing.T) {
	var input bytes.Buffer
	if err := binary.Write(&input, binary.LittleEndian, uint32(maxMessageBytes+1)); err != nil {
		t.Fatal(err)
	}
	if err := processMessage(&input, &bytes.Buffer{}, fakeHandler{}); err == nil {
		t.Fatalf("expected oversized frame to fail")
	}
}
