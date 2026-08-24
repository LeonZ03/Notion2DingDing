package handler

import (
	"testing"

	"github.com/LeonZ03/Notion2DingDing/apps/native-host/internal/protocol"
)

func TestHealthCheck(t *testing.T) {
	response := Handle(protocol.Request{
		ProtocolVersion: protocol.Version,
		RequestID:       "request-1",
		Method:          "health.check",
	})

	if !response.OK {
		t.Fatalf("expected successful response, got %#v", response.Error)
	}

	if response.RequestID != "request-1" {
		t.Fatalf("expected request id to be preserved, got %q", response.RequestID)
	}
}

func TestRejectsUnknownMethod(t *testing.T) {
	response := Handle(protocol.Request{
		ProtocolVersion: protocol.Version,
		RequestID:       "request-2",
		Method:          "unknown.method",
	})

	if response.OK || response.Error == nil {
		t.Fatalf("expected an error response, got %#v", response)
	}

	if response.Error.Code != "method_not_found" {
		t.Fatalf("unexpected error code %q", response.Error.Code)
	}
}
