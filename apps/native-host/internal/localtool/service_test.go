package localtool

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"

	"github.com/LeonZ03/Notion2DingDing/apps/native-host/internal/protocol"
)

func TestValidateExport(t *testing.T) {
	raw := []byte{'P', 'K', 3, 4, 1, 2, 3}
	decoded, failure := validateExport(protocol.MigrationExportParams{
		FileName:      "notion-export.zip",
		ContentBase64: base64.StdEncoding.EncodeToString(raw),
	})
	if failure != nil {
		t.Fatalf("expected valid export, got %#v", failure)
	}
	if string(decoded) != string(raw) {
		t.Fatalf("decoded payload mismatch")
	}
}

func TestValidateExportRejectsPathsAndNonZip(t *testing.T) {
	content := base64.StdEncoding.EncodeToString([]byte{'P', 'K', 3, 4})
	for _, fileName := range []string{"../secret.zip", `C:\\secret.zip`, "export.md"} {
		_, failure := validateExport(protocol.MigrationExportParams{
			FileName:      fileName,
			ContentBase64: content,
		})
		if failure == nil || failure.Code != "invalid_export" {
			t.Fatalf("expected invalid_export for %q, got %#v", fileName, failure)
		}
	}
}

func TestValidateExportRejectsPageSnapshotThatClaimsCompleteness(t *testing.T) {
	_, failure := validateExport(protocol.MigrationExportParams{
		FileName:      "export.zip",
		ContentBase64: base64.StdEncoding.EncodeToString([]byte{'P', 'K', 3, 4}),
		SourcePage:    &protocol.PageSnapshot{ExportRequired: false},
	})
	if failure == nil || failure.Code != "invalid_page_snapshot" {
		t.Fatalf("expected invalid_page_snapshot, got %#v", failure)
	}
}

func TestValidateExportRejectsUnknownSubpageMode(t *testing.T) {
	_, failure := validateExport(protocol.MigrationExportParams{
		FileName:      "export.zip",
		ContentBase64: base64.StdEncoding.EncodeToString([]byte{'P', 'K', 3, 4}),
		SubpageMode:   "unknown",
	})
	if failure == nil || failure.Code != "invalid_subpage_mode" {
		t.Fatalf("expected invalid_subpage_mode, got %#v", failure)
	}
}

func TestDingTalkDocumentURLValidation(t *testing.T) {
	if !isDingTalkDocumentURL("https://alidocs.dingtalk.com/i/nodes/test") {
		t.Fatal("expected a DingTalk document URL")
	}
	for _, value := range []string{
		"http://alidocs.dingtalk.com/i/nodes/test",
		"https://alidocs.dingtalk.com.evil.example/i/nodes/test",
		"javascript:alert(1)",
	} {
		if isDingTalkDocumentURL(value) {
			t.Fatalf("expected URL to be rejected: %s", value)
		}
	}
}

func TestRemoveOwnedTaskDirectory(t *testing.T) {
	root := t.TempDir()
	task := filepath.Join(root, "task-owned")
	if err := os.Mkdir(task, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(task, "source.zip"), []byte("owned"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := removeOwnedTaskDirectory(task, root); err != nil {
		t.Fatalf("cleanup failed: %v", err)
	}
	if _, err := os.Stat(task); !os.IsNotExist(err) {
		t.Fatalf("task directory still exists")
	}
	if err := removeOwnedTaskDirectory(root, root); err == nil {
		t.Fatalf("expected owned-root deletion to be refused")
	}
}

func TestMigrationResultIsMinimal(t *testing.T) {
	var payload migrationPayload
	payload.TaskID = "task-1"
	payload.Remote.TaskID = "remote-1"
	payload.Remote.DocumentURL = "https://alidocs.dingtalk.com/i/nodes/test"
	payload.Checks.ExpectedImageCount = 8
	payload.Checks.ReadbackImageCount = 8
	payload.Checks.NativeTodoCount = 2
	payload.Checks.NativeCodeBlockCount = 3
	payload.Checks.NativeLayoutCount = 2
	payload.Checks.RecursivePageCount = 3
	payload.Checks.RecursiveFolderCount = 3
	payload.Checks.RecursiveLinkCount = 2
	payload.Cleanup.Verified = true

	result := migrationResult(payload, true)
	if result.TaskID != "task-1" || result.ExpectedImageCount != 8 || result.NativeCodeBlockCount != 3 || result.NativeLayoutCount != 2 || result.SubpageMode != "tree" || result.RecursivePageCount != 3 || result.RecursiveFolderCount != 3 || result.RecursiveLinkCount != 2 || !result.CleanupVerified || !result.SourcePageCaptured {
		t.Fatalf("unexpected result: %#v", result)
	}
}

func TestReadConfiguredTargetOnlyReturnsDisplayInformation(t *testing.T) {
	dataDirectory := t.TempDir()
	config := []byte(`{"folder":"private-node-id","folderName":"我的文件 / 验证输出","profile":"private-profile"}`)
	if err := os.WriteFile(filepath.Join(dataDirectory, "config.json"), config, 0o600); err != nil {
		t.Fatal(err)
	}

	targetType, displayName := readConfiguredTarget(dataDirectory)
	if targetType != "folder" || displayName != "我的文件 / 验证输出" {
		t.Fatalf("unexpected target display: %q %q", targetType, displayName)
	}
}

func TestFindPreviousExportReturnsConfirmedDocumentAndCount(t *testing.T) {
	dataDirectory := t.TempDir()
	if err := os.WriteFile(
		filepath.Join(dataDirectory, "config.json"),
		[]byte(`{"folder":"folder-1","folderName":"验证输出"}`),
		0o600,
	); err != nil {
		t.Fatal(err)
	}
	stateDirectory := filepath.Join(dataDirectory, "state", "migrations")
	if err := os.MkdirAll(stateDirectory, 0o700); err != nil {
		t.Fatal(err)
	}
	raw := []byte{'P', 'K', 3, 4, 9}
	sum := sha256.Sum256(raw)
	sourceHash := hex.EncodeToString(sum[:])
	records := map[string]string{
		"unknown.json": `{"success":false,"status":"unknown","updatedAt":"2026-08-28T02:00:00Z","source":{"sha256":"` + sourceHash + `"},"target":{"type":"folder","id":"folder-1"},"remote":{"documentUrl":"https://alidocs.dingtalk.com/i/nodes/unknown"}}`,
		"success.json": `{"success":true,"status":"success","completedAt":"2026-08-28T01:00:00Z","source":{"sha256":"` + sourceHash + `"},"target":{"type":"folder","id":"folder-1"},"remote":{"documentUrl":"https://alidocs.dingtalk.com/i/nodes/success"}}`,
		"other.json":   `{"success":true,"status":"success","source":{"sha256":"` + sourceHash + `"},"target":{"type":"folder","id":"other"},"remote":{"documentUrl":"https://alidocs.dingtalk.com/i/nodes/other"}}`,
	}
	for name, content := range records {
		if err := os.WriteFile(filepath.Join(stateDirectory, name), []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	previous := findPreviousExport(dataDirectory, raw)
	if previous == nil || previous.Status != "success" ||
		previous.DocumentURL != "https://alidocs.dingtalk.com/i/nodes/success" ||
		previous.Count != 2 || previous.SubpageMode != "inline" {
		t.Fatalf("unexpected previous export: %#v", previous)
	}
}

func TestTreeStateUsesRootDocumentAsPreviousExport(t *testing.T) {
	var record migrationStateRecord
	record.Mode = "tree"
	record.Pages = make([]struct {
		ParentPageKey string `json:"parentPageKey"`
		Remote        struct {
			DocumentURL string `json:"documentUrl"`
		} `json:"remote"`
	}, 2)
	record.Pages[0].Remote.DocumentURL = "https://alidocs.dingtalk.com/i/nodes/root"
	record.Pages[1].ParentPageKey = "root-page"
	record.Pages[1].Remote.DocumentURL = "https://alidocs.dingtalk.com/i/nodes/child"
	documentURL, mode := stateRecordDocumentURL(record)
	if documentURL != "https://alidocs.dingtalk.com/i/nodes/root" || mode != "tree" {
		t.Fatalf("unexpected tree previous export: %q %q", documentURL, mode)
	}
}
