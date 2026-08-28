package handler

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"runtime"
	"strings"

	"github.com/LeonZ03/Notion2DingDing/apps/native-host/internal/protocol"
)

const HostVersion = "0.3.3"

type LocalTool interface {
	Health() protocol.LocalToolStatus
	OpenLocalTool(string) (protocol.LocalOpenResult, *protocol.Error)
	InspectExport(protocol.MigrationExportParams) (protocol.MigrationExportInspection, *protocol.Error)
	MigrateExport(protocol.MigrationExportParams) (protocol.MigrationResult, *protocol.Error)
	StartMigration(protocol.MigrationExportParams) (protocol.MigrationTaskSnapshot, *protocol.Error)
	MigrationStatus(string) (protocol.MigrationTaskSnapshot, *protocol.Error)
	CancelMigration(string) (protocol.MigrationTaskSnapshot, *protocol.Error)
}

type Handler struct {
	localTool LocalTool
}

func New(localTool LocalTool) *Handler {
	return &Handler{localTool: localTool}
}

func (h *Handler) Handle(request protocol.Request) protocol.Response {
	if request.ProtocolVersion != protocol.Version {
		return protocol.Failure(
			request.RequestID,
			"unsupported_protocol_version",
			"扩展与本地助手的协议版本不兼容。",
		)
	}

	if strings.TrimSpace(request.RequestID) == "" {
		return protocol.Failure("", "invalid_request", "requestId 不能为空。")
	}

	switch request.Method {
	case "health.check":
		return protocol.Response{
			ProtocolVersion: protocol.Version,
			RequestID:       request.RequestID,
			OK:              true,
			Result: protocol.HealthResult{
				HostVersion:     HostVersion,
				ProtocolVersion: protocol.Version,
				Platform:        runtime.GOOS + "/" + runtime.GOARCH,
				Capabilities: []string{
					"health.check",
					"local.open",
					"migration.inspect",
					"migration.export",
					"migration.start",
					"migration.status",
					"migration.cancel",
				},
				LocalTool: h.localTool.Health(),
			},
		}
	case "local.open":
		var params protocol.LocalOpenParams
		if err := decodeParams(request.Params, &params); err != nil {
			return protocol.Failure(request.RequestID, "invalid_params", "打开本地设置的参数无效："+err.Error())
		}
		result, failure := h.localTool.OpenLocalTool(params.Action)
		if failure != nil {
			return protocol.FailureWithDetails(
				request.RequestID,
				failure.Code,
				failure.Message,
				failure.Details,
			)
		}
		return protocol.Response{
			ProtocolVersion: protocol.Version,
			RequestID:       request.RequestID,
			OK:              true,
			Result:          result,
		}
	case "migration.export":
		var params protocol.MigrationExportParams
		if err := decodeParams(request.Params, &params); err != nil {
			return protocol.Failure(request.RequestID, "invalid_params", "迁移参数无效："+err.Error())
		}
		result, failure := h.localTool.MigrateExport(params)
		if failure != nil {
			return protocol.FailureWithDetails(
				request.RequestID,
				failure.Code,
				failure.Message,
				failure.Details,
			)
		}
		return protocol.Response{
			ProtocolVersion: protocol.Version,
			RequestID:       request.RequestID,
			OK:              true,
			Result:          result,
		}
	case "migration.inspect":
		var params protocol.MigrationExportParams
		if err := decodeParams(request.Params, &params); err != nil {
			return protocol.Failure(request.RequestID, "invalid_params", "导出包检查参数无效："+err.Error())
		}
		result, failure := h.localTool.InspectExport(params)
		if failure != nil {
			return protocol.FailureWithDetails(request.RequestID, failure.Code, failure.Message, failure.Details)
		}
		return protocol.Response{
			ProtocolVersion: protocol.Version,
			RequestID:       request.RequestID,
			OK:              true,
			Result:          result,
		}
	case "migration.start":
		var params protocol.MigrationExportParams
		if err := decodeParams(request.Params, &params); err != nil {
			return protocol.Failure(request.RequestID, "invalid_params", "迁移参数无效："+err.Error())
		}
		result, failure := h.localTool.StartMigration(params)
		if failure != nil {
			return protocol.FailureWithDetails(request.RequestID, failure.Code, failure.Message, failure.Details)
		}
		return protocol.Response{
			ProtocolVersion: protocol.Version,
			RequestID:       request.RequestID,
			OK:              true,
			Result:          result,
		}
	case "migration.status", "migration.cancel":
		var params protocol.MigrationTaskParams
		if err := decodeParams(request.Params, &params); err != nil {
			return protocol.Failure(request.RequestID, "invalid_params", "任务参数无效："+err.Error())
		}
		var result protocol.MigrationTaskSnapshot
		var failure *protocol.Error
		if request.Method == "migration.status" {
			result, failure = h.localTool.MigrationStatus(params.TaskID)
		} else {
			result, failure = h.localTool.CancelMigration(params.TaskID)
		}
		if failure != nil {
			return protocol.FailureWithDetails(request.RequestID, failure.Code, failure.Message, failure.Details)
		}
		return protocol.Response{
			ProtocolVersion: protocol.Version,
			RequestID:       request.RequestID,
			OK:              true,
			Result:          result,
		}
	default:
		return protocol.Failure(
			request.RequestID,
			"method_not_found",
			"本地助手暂不支持该操作。",
		)
	}
}

func decodeParams(raw json.RawMessage, target any) error {
	if len(bytes.TrimSpace(raw)) == 0 {
		raw = json.RawMessage("{}")
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return errors.New("参数只能包含一个 JSON 对象")
	}
	return nil
}
