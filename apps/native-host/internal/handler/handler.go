package handler

import (
	"runtime"

	"github.com/LeonZ03/Notion2DingDing/apps/native-host/internal/protocol"
)

const HostVersion = "0.1.0"

type HealthResult struct {
	HostVersion  string   `json:"hostVersion"`
	Platform     string   `json:"platform"`
	Capabilities []string `json:"capabilities"`
}

func Handle(request protocol.Request) protocol.Response {
	if request.ProtocolVersion != protocol.Version {
		return protocol.Failure(
			request.RequestID,
			"unsupported_protocol_version",
			"扩展与本地助手的协议版本不兼容。",
		)
	}

	if request.RequestID == "" {
		return protocol.Failure("", "invalid_request", "requestId 不能为空。")
	}

	switch request.Method {
	case "health.check":
		return protocol.Response{
			ProtocolVersion: protocol.Version,
			RequestID:       request.RequestID,
			OK:              true,
			Result: HealthResult{
				HostVersion:  HostVersion,
				Platform:     runtime.GOOS + "/" + runtime.GOARCH,
				Capabilities: []string{"health.check"},
			},
		}
	default:
		return protocol.Failure(
			request.RequestID,
			"method_not_found",
			"本地助手暂不支持该操作。",
		)
	}
}
