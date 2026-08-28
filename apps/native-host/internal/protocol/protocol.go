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
	Code    string         `json:"code"`
	Message string         `json:"message"`
	Details map[string]any `json:"details,omitempty"`
}

type Response struct {
	ProtocolVersion int    `json:"protocolVersion"`
	RequestID       string `json:"requestId"`
	OK              bool   `json:"ok"`
	Result          any    `json:"result,omitempty"`
	Error           *Error `json:"error,omitempty"`
}

type LocalToolStatus struct {
	Installed         bool   `json:"installed"`
	Version           string `json:"version,omitempty"`
	Ready             bool   `json:"ready"`
	Authenticated     bool   `json:"authenticated"`
	Configured        bool   `json:"configured"`
	TargetType        string `json:"targetType,omitempty"`
	TargetDisplayName string `json:"targetDisplayName,omitempty"`
	Message           string `json:"message"`
}

type LocalOpenParams struct {
	Action string `json:"action"`
}

type LocalOpenResult struct {
	Started bool   `json:"started"`
	Action  string `json:"action"`
	Message string `json:"message"`
}

type HealthResult struct {
	HostVersion     string          `json:"hostVersion"`
	ProtocolVersion int             `json:"protocolVersion"`
	Platform        string          `json:"platform"`
	Capabilities    []string        `json:"capabilities"`
	LocalTool       LocalToolStatus `json:"localTool"`
}

type PageSnapshot struct {
	URL               string `json:"url,omitempty"`
	Title             string `json:"title,omitempty"`
	VisibleTextBytes  int    `json:"visibleTextBytes,omitempty"`
	VisibleBlockCount int    `json:"visibleBlockCount,omitempty"`
	VisibleImageCount int    `json:"visibleImageCount,omitempty"`
	ExportRequired    bool   `json:"exportRequired"`
}

type MigrationExportParams struct {
	FileName      string        `json:"fileName"`
	ContentBase64 string        `json:"contentBase64"`
	Title         string        `json:"title,omitempty"`
	SubpageMode   string        `json:"subpageMode,omitempty"`
	CreateNew     bool          `json:"createNew,omitempty"`
	SourcePage    *PageSnapshot `json:"sourcePage,omitempty"`
}

type MigrationExportInspection struct {
	FileName       string                   `json:"fileName"`
	Title          string                   `json:"title"`
	ExportedAt     string                   `json:"exportedAt"`
	PageCount      int                      `json:"pageCount"`
	Bytes          int                      `json:"bytes"`
	PreviousExport *MigrationPreviousExport `json:"previousExport,omitempty"`
}

type MigrationPreviousExport struct {
	Status      string `json:"status"`
	DocumentURL string `json:"documentUrl"`
	UpdatedAt   string `json:"updatedAt"`
	Count       int    `json:"count"`
	SubpageMode string `json:"subpageMode"`
}

type MigrationResult struct {
	TaskID                    string `json:"taskId"`
	RemoteTaskID              string `json:"remoteTaskId,omitempty"`
	DocumentURL               string `json:"documentUrl"`
	Reused                    bool   `json:"reused"`
	ExpectedImageCount        int    `json:"expectedImageCount"`
	ReadbackImageCount        int    `json:"readbackImageCount"`
	NativeTodoCount           int    `json:"nativeTodoCount"`
	NativeCodeBlockCount      int    `json:"nativeCodeBlockCount"`
	NativeLayoutCount         int    `json:"nativeLayoutCount"`
	NativeSubpageTocItemCount int    `json:"nativeSubpageTocItemCount"`
	SubpageMode               string `json:"subpageMode,omitempty"`
	RecursivePageCount        int    `json:"recursivePageCount,omitempty"`
	RecursiveFolderCount      int    `json:"recursiveFolderCount,omitempty"`
	RecursiveLinkCount        int    `json:"recursiveLinkCount,omitempty"`
	CleanupVerified           bool   `json:"cleanupVerified"`
	SourcePageCaptured        bool   `json:"sourcePageCaptured"`
}

type MigrationTaskParams struct {
	TaskID string `json:"taskId"`
}

type MigrationTaskProgress struct {
	Current int    `json:"current"`
	Total   int    `json:"total"`
	Percent int    `json:"percent"`
	Stage   string `json:"stage"`
	Message string `json:"message"`
}

type MigrationTaskSnapshot struct {
	TaskID         string                `json:"taskId"`
	Status         string                `json:"status"`
	Progress       MigrationTaskProgress `json:"progress"`
	CanCancel      bool                  `json:"canCancel"`
	RecoveryAction string                `json:"recoveryAction,omitempty"`
	UpdatedAt      string                `json:"updatedAt"`
	Result         *MigrationResult      `json:"result,omitempty"`
	Error          *Error                `json:"error,omitempty"`
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

func FailureWithDetails(requestID, code, message string, details map[string]any) Response {
	response := Failure(requestID, code, message)
	response.Error.Details = details
	return response
}
