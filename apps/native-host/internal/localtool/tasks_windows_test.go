//go:build windows

package localtool

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/LeonZ03/Notion2DingDing/apps/native-host/internal/protocol"
)

func newTaskTestService(t *testing.T, body string) *Service {
	t.Helper()
	root := t.TempDir()
	script := filepath.Join(root, "fake-cli.ps1")
	if err := os.WriteFile(script, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	powershell := filepath.Join(
		os.Getenv("SystemRoot"),
		"System32", "WindowsPowerShell", "v1.0", "powershell.exe",
	)
	return &Service{
		cliScript:     script,
		powershell:    powershell,
		dataDirectory: root,
		tasks:         make(map[string]*migrationTask),
	}
}

func taskTestParams() protocol.MigrationExportParams {
	return protocol.MigrationExportParams{
		FileName:      "export.zip",
		ContentBase64: base64.StdEncoding.EncodeToString([]byte{'P', 'K', 3, 4, 1}),
		Title:         "阶段 6 任务测试",
		CreateNew:     true,
	}
}

func waitForTerminalTask(t *testing.T, service *Service, taskID string) protocol.MigrationTaskSnapshot {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		snapshot, failure := service.MigrationStatus(taskID)
		if failure != nil {
			t.Fatal(failure)
		}
		switch snapshot.Status {
		case "succeeded", "failed", "unknown", "cancelled":
			return snapshot
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatal("task did not reach a terminal state")
	return protocol.MigrationTaskSnapshot{}
}

func TestAsyncMigrationReportsProgressAndSuccess(t *testing.T) {
	service := newTaskTestService(t, `param([Parameter(Position=0)][string]$Command,[Parameter(ValueFromRemainingArguments=$true)][string[]]$Remaining)
$ErrorActionPreference='Stop'
if ($Remaining -notcontains '--force') { throw 'missing --force' }
[Console]::Error.WriteLine('[1/5] preflight')
[Console]::Error.WriteLine('[3/5] import')
$result=[ordered]@{success=$true;status='SUCCESS';stage='verified';taskId='core-task';remote=[ordered]@{taskId='remote-task';documentUrl='https://alidocs.dingtalk.com/i/nodes/test'};checks=[ordered]@{expectedImageCount=1;readbackImageCount=1;nativeTodoCount=0;todosMatch=$true};cleanup=[ordered]@{verified=$true}}
[Console]::Out.Write(($result|ConvertTo-Json -Depth 8 -Compress))
`)
	defer service.Shutdown()
	started, failure := service.StartMigration(taskTestParams())
	if failure != nil {
		t.Fatal(failure)
	}
	if (started.Status != "queued" && started.Status != "running") || !started.CanCancel {
		t.Fatalf("unexpected started task: %#v", started)
	}
	final := waitForTerminalTask(t, service, started.TaskID)
	if final.Status != "succeeded" || final.Progress.Percent != 100 || final.Result == nil {
		t.Fatalf("unexpected final task: %#v error=%#v", final, final.Error)
	}
	tasksRoot := filepath.Join(service.dataDirectory, "native-host", "tasks")
	entries, err := os.ReadDir(tasksRoot)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("staging task was not cleaned: %#v", entries)
	}
}

func TestAsyncMigrationCanBeCancelledAndCleansStaging(t *testing.T) {
	service := newTaskTestService(t, `param([Parameter(Position=0)][string]$Command,[Parameter(ValueFromRemainingArguments=$true)][string[]]$Remaining)
$ErrorActionPreference='Stop'
[Console]::Error.WriteLine('[1/5] preflight')
Start-Sleep -Seconds 30
`)
	defer service.Shutdown()
	started, failure := service.StartMigration(taskTestParams())
	if failure != nil {
		t.Fatal(failure)
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		snapshot, statusFailure := service.MigrationStatus(started.TaskID)
		if statusFailure != nil {
			t.Fatal(statusFailure)
		}
		if snapshot.Status == "running" {
			break
		}
		time.Sleep(25 * time.Millisecond)
	}
	requested, cancelFailure := service.CancelMigration(started.TaskID)
	if cancelFailure != nil {
		t.Fatal(cancelFailure)
	}
	if requested.Status != "cancel_requested" && requested.Status != "cancelled" {
		t.Fatalf("unexpected cancellation response: %#v", requested)
	}
	final := waitForTerminalTask(t, service, started.TaskID)
	if final.Status != "cancelled" || final.RecoveryAction != "retry" {
		t.Fatalf("unexpected cancelled task: %#v", final)
	}
	tasksRoot := filepath.Join(service.dataDirectory, "native-host", "tasks")
	entries, err := os.ReadDir(tasksRoot)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("cancelled staging task was not cleaned: %#v", entries)
	}
}

func TestMigrationCannotBeCancelledAfterRemoteWriteBegins(t *testing.T) {
	taskID := "0123456789abcdef"
	task := &migrationTask{
		done: make(chan struct{}),
		snapshot: protocol.MigrationTaskSnapshot{
			TaskID:    taskID,
			Status:    "running",
			CanCancel: true,
			Progress: protocol.MigrationTaskProgress{
				Current: 1,
				Total:   5,
				Percent: 18,
				Stage:   "preflight",
				Message: "preflight",
			},
		},
	}
	service := &Service{tasks: map[string]*migrationTask{taskID: task}}
	task.updateProgress(3, 5, "import", "writing")
	snapshot, failure := service.CancelMigration(taskID)
	if failure != nil {
		t.Fatal(failure)
	}
	if snapshot.Status != "running" || snapshot.CanCancel {
		t.Fatalf("remote write task must keep running: %#v", snapshot)
	}
	if snapshot.Progress.Message != "钉钉写入已经开始，不能再安全取消；请等待导入与回读完成。" {
		t.Fatalf("unexpected cancellation guidance: %q", snapshot.Progress.Message)
	}
}
