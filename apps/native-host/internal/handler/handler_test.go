package handler

import (
	"encoding/json"
	"testing"

	"github.com/LeonZ03/Notion2DingDing/apps/native-host/internal/protocol"
)

type fakeLocalTool struct {
	health           protocol.LocalToolStatus
	migrationResult  protocol.MigrationResult
	migrationError   *protocol.Error
	inspectionResult protocol.MigrationExportInspection
	inspectionError  *protocol.Error
	lastParams       protocol.MigrationExportParams
	openResult       protocol.LocalOpenResult
	openError        *protocol.Error
	lastOpenAction   string
	taskSnapshot     protocol.MigrationTaskSnapshot
	taskError        *protocol.Error
	lastTaskID       string
}

func (f *fakeLocalTool) Health() protocol.LocalToolStatus {
	return f.health
}

func (f *fakeLocalTool) OpenLocalTool(action string) (protocol.LocalOpenResult, *protocol.Error) {
	f.lastOpenAction = action
	return f.openResult, f.openError
}

func (f *fakeLocalTool) MigrateExport(params protocol.MigrationExportParams) (
	protocol.MigrationResult,
	*protocol.Error,
) {
	f.lastParams = params
	return f.migrationResult, f.migrationError
}

func (f *fakeLocalTool) InspectExport(params protocol.MigrationExportParams) (
	protocol.MigrationExportInspection,
	*protocol.Error,
) {
	f.lastParams = params
	return f.inspectionResult, f.inspectionError
}

func (f *fakeLocalTool) StartMigration(params protocol.MigrationExportParams) (
	protocol.MigrationTaskSnapshot,
	*protocol.Error,
) {
	f.lastParams = params
	return f.taskSnapshot, f.taskError
}

func (f *fakeLocalTool) MigrationStatus(taskID string) (protocol.MigrationTaskSnapshot, *protocol.Error) {
	f.lastTaskID = taskID
	return f.taskSnapshot, f.taskError
}

func (f *fakeLocalTool) CancelMigration(taskID string) (protocol.MigrationTaskSnapshot, *protocol.Error) {
	f.lastTaskID = taskID
	return f.taskSnapshot, f.taskError
}

func TestLocalOpenUsesLocalTool(t *testing.T) {
	tool := &fakeLocalTool{openResult: protocol.LocalOpenResult{
		Started: true,
		Action:  "target",
		Message: "opened",
	}}
	response := New(tool).Handle(protocol.Request{
		ProtocolVersion: protocol.Version,
		RequestID:       "request-open",
		Method:          "local.open",
		Params:          json.RawMessage(`{"action":"target"}`),
	})

	if !response.OK || tool.lastOpenAction != "target" {
		t.Fatalf("expected local target picker to open, got %#v", response)
	}
}

func TestHealthCheck(t *testing.T) {
	tool := &fakeLocalTool{health: protocol.LocalToolStatus{Installed: true, Ready: true}}
	response := New(tool).Handle(protocol.Request{
		ProtocolVersion: protocol.Version,
		RequestID:       "request-1",
		Method:          "health.check",
		Params:          json.RawMessage(`{}`),
	})

	if !response.OK {
		t.Fatalf("expected successful response, got %#v", response.Error)
	}
	if response.RequestID != "request-1" {
		t.Fatalf("expected request id to be preserved, got %q", response.RequestID)
	}
	health, ok := response.Result.(protocol.HealthResult)
	if !ok || !health.LocalTool.Ready {
		t.Fatalf("expected ready local tool health, got %#v", response.Result)
	}
}

func TestMigrationExportUsesLocalTool(t *testing.T) {
	tool := &fakeLocalTool{migrationResult: protocol.MigrationResult{
		TaskID:      "task-1",
		DocumentURL: "https://alidocs.dingtalk.com/i/nodes/test",
	}}
	response := New(tool).Handle(protocol.Request{
		ProtocolVersion: protocol.Version,
		RequestID:       "request-2",
		Method:          "migration.export",
		Params: json.RawMessage(`{
			"fileName":"export.zip",
			"contentBase64":"UEsDBA==",
			"title":"验证标题",
			"subpageMode":"tree",
			"createNew":true
		}`),
	})

	if !response.OK {
		t.Fatalf("expected successful response, got %#v", response.Error)
	}
	if tool.lastParams.FileName != "export.zip" || tool.lastParams.Title != "验证标题" || tool.lastParams.SubpageMode != "tree" || !tool.lastParams.CreateNew {
		t.Fatalf("unexpected params: %#v", tool.lastParams)
	}
}

func TestMigrationInspectUsesLocalTool(t *testing.T) {
	tool := &fakeLocalTool{inspectionResult: protocol.MigrationExportInspection{
		FileName: "export.zip", Title: "导出包标题", ExportedAt: "2026-08-28T02:00:00Z", PageCount: 3, Bytes: 1024,
	}}
	response := New(tool).Handle(protocol.Request{
		ProtocolVersion: protocol.Version,
		RequestID:       "request-inspect",
		Method:          "migration.inspect",
		Params:          json.RawMessage(`{"fileName":"export.zip","contentBase64":"UEsDBA=="}`),
	})
	if !response.OK || tool.lastParams.FileName != "export.zip" {
		t.Fatalf("expected export inspection, got %#v", response)
	}
	result, ok := response.Result.(protocol.MigrationExportInspection)
	if !ok || result.Title != "导出包标题" || result.PageCount != 3 {
		t.Fatalf("unexpected inspection result: %#v", response.Result)
	}
}

func TestRejectsUnknownMigrationParams(t *testing.T) {
	response := New(&fakeLocalTool{}).Handle(protocol.Request{
		ProtocolVersion: protocol.Version,
		RequestID:       "request-3",
		Method:          "migration.export",
		Params:          json.RawMessage(`{"fileName":"x.zip","contentBase64":"UEsDBA==","unknown":true}`),
	})

	if response.OK || response.Error == nil || response.Error.Code != "invalid_params" {
		t.Fatalf("expected invalid_params, got %#v", response)
	}
}

func TestMigrationTaskLifecycleUsesLocalTool(t *testing.T) {
	tool := &fakeLocalTool{taskSnapshot: protocol.MigrationTaskSnapshot{
		TaskID: "0123456789abcdef",
		Status: "running",
	}}
	handler := New(tool)
	started := handler.Handle(protocol.Request{
		ProtocolVersion: protocol.Version,
		RequestID:       "task-start",
		Method:          "migration.start",
		Params:          json.RawMessage(`{"fileName":"export.zip","contentBase64":"UEsDBA=="}`),
	})
	if !started.OK || tool.lastParams.FileName != "export.zip" {
		t.Fatalf("expected task start, got %#v", started)
	}
	status := handler.Handle(protocol.Request{
		ProtocolVersion: protocol.Version,
		RequestID:       "task-status",
		Method:          "migration.status",
		Params:          json.RawMessage(`{"taskId":"0123456789abcdef"}`),
	})
	if !status.OK || tool.lastTaskID != "0123456789abcdef" {
		t.Fatalf("expected task status, got %#v", status)
	}
	cancelled := handler.Handle(protocol.Request{
		ProtocolVersion: protocol.Version,
		RequestID:       "task-cancel",
		Method:          "migration.cancel",
		Params:          json.RawMessage(`{"taskId":"0123456789abcdef"}`),
	})
	if !cancelled.OK || tool.lastTaskID != "0123456789abcdef" {
		t.Fatalf("expected task cancellation, got %#v", cancelled)
	}
}

func TestRejectsUnknownMethod(t *testing.T) {
	response := New(&fakeLocalTool{}).Handle(protocol.Request{
		ProtocolVersion: protocol.Version,
		RequestID:       "request-4",
		Method:          "unknown.method",
	})

	if response.OK || response.Error == nil {
		t.Fatalf("expected an error response, got %#v", response)
	}
	if response.Error.Code != "method_not_found" {
		t.Fatalf("unexpected error code %q", response.Error.Code)
	}
}
