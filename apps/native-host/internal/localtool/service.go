package localtool

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/LeonZ03/Notion2DingDing/apps/native-host/internal/protocol"
)

const (
	maxExportBytes  = 64 * 1024 * 1024
	maxEncodedBytes = ((maxExportBytes + 2) / 3) * 4
	commandTimeout  = 30 * time.Minute
)

type Service struct {
	cliScript     string
	guiScript     string
	powershell    string
	dataDirectory string
	tasksMu       sync.Mutex
	tasks         map[string]*migrationTask
	closing       bool
	tasksWG       sync.WaitGroup
}

type commandResult struct {
	stdout   []byte
	stderr   []byte
	exitCode int
	err      error
}

type migrationPayload struct {
	Success bool   `json:"success"`
	Status  string `json:"status"`
	Stage   string `json:"stage"`
	TaskID  string `json:"taskId"`
	Reused  bool   `json:"reused"`
	Remote  struct {
		TaskID      string `json:"taskId"`
		DocumentURL string `json:"documentUrl"`
	} `json:"remote"`
	Checks struct {
		ExpectedImageCount        int  `json:"expectedImageCount"`
		ReadbackImageCount        int  `json:"readbackImageCount"`
		NativeTodoCount           int  `json:"nativeTodoCount"`
		NativeCodeBlockCount      int  `json:"nativeCodeBlockCount"`
		NativeLayoutCount         int  `json:"nativeLayoutCount"`
		NativeSubpageTocItemCount int  `json:"nativeSubpageTocItemCount"`
		RecursivePageCount        int  `json:"recursivePageCount"`
		RecursiveFolderCount      int  `json:"recursiveFolderCount"`
		RecursiveLinkCount        int  `json:"recursiveLinkCount"`
		TodosMatch                bool `json:"todosMatch"`
	} `json:"checks"`
	Cleanup struct {
		Verified bool `json:"verified"`
	} `json:"cleanup"`
	Error struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

type exportInspectionPayload struct {
	Success     bool   `json:"success"`
	InputFormat string `json:"inputFormat"`
	Mode        string `json:"mode"`
	Title       string `json:"title"`
	ExportedAt  string `json:"exportedAt"`
	PageCount   int    `json:"pageCount"`
	Error       struct {
		Message string `json:"message"`
	} `json:"error"`
}

type configuredTarget struct {
	Type        string
	ID          string
	DisplayName string
}

type migrationStateRecord struct {
	Success     bool   `json:"success"`
	Status      string `json:"status"`
	Mode        string `json:"mode"`
	StartedAt   string `json:"startedAt"`
	UpdatedAt   string `json:"updatedAt"`
	CompletedAt string `json:"completedAt"`
	Source      struct {
		SHA256 string `json:"sha256"`
	} `json:"source"`
	Target struct {
		Type string `json:"type"`
		ID   string `json:"id"`
	} `json:"target"`
	Remote struct {
		DocumentURL string `json:"documentUrl"`
	} `json:"remote"`
	Pages []struct {
		ParentPageKey string `json:"parentPageKey"`
		Remote        struct {
			DocumentURL string `json:"documentUrl"`
		} `json:"remote"`
	} `json:"pages"`
}

type previousExportCandidate struct {
	status      string
	documentURL string
	updatedAt   string
	updatedTime time.Time
	subpageMode string
}

func New() *Service {
	localAppData := strings.TrimSpace(os.Getenv("LOCALAPPDATA"))
	dataDirectory := strings.TrimSpace(os.Getenv("N2DD_HOST_DATA_DIRECTORY"))
	if dataDirectory == "" && localAppData != "" {
		dataDirectory = filepath.Join(localAppData, "Notion2DingDing")
	}

	cliScript := strings.TrimSpace(os.Getenv("N2DD_HOST_CLI_SCRIPT"))
	if cliScript == "" && localAppData != "" {
		cliScript = filepath.Join(
			localAppData,
			"Programs",
			"Notion2DingDing",
			"cli",
			"notion2dingding.ps1",
		)
	}

	powershell := strings.TrimSpace(os.Getenv("N2DD_HOST_POWERSHELL"))
	if powershell == "" {
		systemRoot := strings.TrimSpace(os.Getenv("SystemRoot"))
		if systemRoot != "" {
			powershell = filepath.Join(
				systemRoot,
				"System32",
				"WindowsPowerShell",
				"v1.0",
				"powershell.exe",
			)
		}
	}

	return &Service{
		cliScript:     cliScript,
		guiScript:     filepath.Join(filepath.Dir(cliScript), "notion2dingding-gui.ps1"),
		powershell:    powershell,
		dataDirectory: dataDirectory,
		tasks:         make(map[string]*migrationTask),
	}
}

func (s *Service) Health() protocol.LocalToolStatus {
	status := protocol.LocalToolStatus{
		Installed: false,
		Ready:     false,
		Message:   "尚未安装阶段 4 本地工具。",
	}
	if !isFile(s.cliScript) {
		return status
	}
	status.Installed = true

	versionResult := s.runCLI(30*time.Second, "version")
	var versionPayload struct {
		Success bool   `json:"success"`
		Version string `json:"version"`
	}
	if versionResult.exitCode != 0 || json.Unmarshal(versionResult.stdout, &versionPayload) != nil || !versionPayload.Success {
		status.Message = "本地工具已安装，但无法读取版本。请重新运行安装或升级。"
		return status
	}
	status.Version = versionPayload.Version

	doctorResult := s.runCLI(2*time.Minute, "doctor", "-NoExitCode")
	var doctorPayload struct {
		Ready  bool `json:"ready"`
		Checks []struct {
			Name  string `json:"name"`
			Ready bool   `json:"ready"`
		} `json:"checks"`
	}
	if doctorResult.exitCode != 0 || json.Unmarshal(doctorResult.stdout, &doctorPayload) != nil {
		status.Message = "本地工具诊断失败，请从开始菜单运行环境检查。"
		return status
	}
	status.Ready = doctorPayload.Ready
	for _, check := range doctorPayload.Checks {
		if check.Name == "config" {
			status.Configured = check.Ready
		}
		if check.Name == "dwsAuth" {
			status.Authenticated = check.Ready
		}
	}
	status.TargetType, status.TargetDisplayName = readConfiguredTarget(s.dataDirectory)
	if status.Ready {
		status.Message = "本地迁移核心已就绪。"
	} else {
		status.Message = "本地迁移核心尚未就绪，请从开始菜单运行环境检查。"
	}
	return status
}

func (s *Service) OpenLocalTool(action string) (protocol.LocalOpenResult, *protocol.Error) {
	action = strings.TrimSpace(action)
	if action != "login" && action != "target" {
		return protocol.LocalOpenResult{}, &protocol.Error{
			Code:    "invalid_open_action",
			Message: "本地工具只支持打开钉钉登录或目标位置选择。",
		}
	}
	if !isFile(s.guiScript) || !isFile(s.powershell) {
		return protocol.LocalOpenResult{}, &protocol.Error{
			Code:    "local_tool_not_installed",
			Message: "未找到已安装的 Notion2DingDing Windows 工具。",
		}
	}
	arguments := []string{
		"-NoProfile",
		"-ExecutionPolicy", "Bypass",
		"-STA",
		"-WindowStyle", "Hidden",
		"-File", s.guiScript,
		"-OpenAction", action,
	}
	command := exec.Command(s.powershell, arguments...)
	// Edge 会在单次 sendNativeMessage 响应后终止 Native Host 的 Job Object。
	// 设置界面必须显式脱离该 Job，否则 Host 虽返回“已打开”，WinForms 也会随即被结束。
	configureDetachedWindow(command)
	if isDirectory(s.dataDirectory) {
		command.Dir = s.dataDirectory
	}
	if err := command.Start(); err != nil {
		return protocol.LocalOpenResult{}, &protocol.Error{
			Code:    "local_tool_open_failed",
			Message: "无法打开 Windows 登录或目标设置窗口。",
		}
	}
	if err := command.Process.Release(); err != nil {
		return protocol.LocalOpenResult{}, &protocol.Error{
			Code:    "local_tool_open_failed",
			Message: "Windows 设置窗口已启动，但进程未能安全分离。",
		}
	}
	message := "已打开 Windows 钉钉登录入口；授权完成后请重新检查环境。"
	if action == "target" {
		message = "已打开 Windows 钉钉文件夹选择器；保存后请重新检查环境。"
	}
	return protocol.LocalOpenResult{Started: true, Action: action, Message: message}, nil
}

func validateExport(params protocol.MigrationExportParams) ([]byte, *protocol.Error) {
	fileName := strings.TrimSpace(params.FileName)
	if fileName == "" || utf8.RuneCountInString(fileName) > 260 || filepath.Base(fileName) != fileName || !strings.EqualFold(filepath.Ext(fileName), ".zip") {
		return nil, &protocol.Error{Code: "invalid_export", Message: "请选择单个 Notion HTML 导出 ZIP。"}
	}
	if utf8.RuneCountInString(strings.TrimSpace(params.Title)) > 200 {
		return nil, &protocol.Error{Code: "invalid_title", Message: "文档标题不能超过 200 个字符。"}
	}
	if params.SubpageMode != "" && params.SubpageMode != "inline" && params.SubpageMode != "tree" {
		return nil, &protocol.Error{Code: "invalid_subpage_mode", Message: "子页面处理方式只支持在同页面内展开或递归文档树。"}
	}
	if params.SourcePage != nil {
		page := params.SourcePage
		if !page.ExportRequired || utf8.RuneCountInString(page.URL) > 4096 || utf8.RuneCountInString(page.Title) > 500 || page.VisibleTextBytes < 0 || page.VisibleBlockCount < 0 || page.VisibleImageCount < 0 {
			return nil, &protocol.Error{Code: "invalid_page_snapshot", Message: "当前页面 DOM 不能作为完整迁移输入，请使用 Notion 官方 HTML 导出 ZIP。"}
		}
	}
	encoded := strings.TrimSpace(params.ContentBase64)
	if encoded == "" || len(encoded) > maxEncodedBytes {
		return nil, &protocol.Error{Code: "export_too_large", Message: "导出 ZIP 不能超过 64 MiB。"}
	}
	raw, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil || len(raw) == 0 {
		return nil, &protocol.Error{Code: "invalid_export", Message: "导出 ZIP 内容无效。"}
	}
	if len(raw) > maxExportBytes {
		return nil, &protocol.Error{Code: "export_too_large", Message: "导出 ZIP 不能超过 64 MiB。"}
	}
	if len(raw) < 4 || raw[0] != 'P' || raw[1] != 'K' {
		return nil, &protocol.Error{Code: "invalid_export", Message: "所选文件不是有效的 ZIP。"}
	}
	return raw, nil
}

func (s *Service) InspectExport(params protocol.MigrationExportParams) (
	protocol.MigrationExportInspection,
	*protocol.Error,
) {
	raw, validationFailure := validateExport(params)
	if validationFailure != nil {
		return protocol.MigrationExportInspection{}, validationFailure
	}
	if !isFile(s.cliScript) {
		return protocol.MigrationExportInspection{}, &protocol.Error{
			Code: "local_tool_not_installed", Message: "未找到已安装的 Notion2DingDing 本地工具。",
		}
	}
	if strings.TrimSpace(s.dataDirectory) == "" {
		return protocol.MigrationExportInspection{}, &protocol.Error{
			Code: "data_directory_unavailable", Message: "无法确定本地工具数据目录。",
		}
	}

	inspectionsRoot := filepath.Join(s.dataDirectory, "native-host", "inspections")
	if err := os.MkdirAll(inspectionsRoot, 0o700); err != nil {
		return protocol.MigrationExportInspection{}, &protocol.Error{
			Code: "inspection_staging_failed", Message: "无法创建导出包检查临时目录。",
		}
	}
	inspectionID, err := randomID()
	if err != nil {
		return protocol.MigrationExportInspection{}, &protocol.Error{
			Code: "inspection_staging_failed", Message: "无法创建导出包检查标识。",
		}
	}
	inspectionDirectory, err := os.MkdirTemp(inspectionsRoot, "inspection-"+inspectionID+"-")
	if err != nil {
		return protocol.MigrationExportInspection{}, &protocol.Error{
			Code: "inspection_staging_failed", Message: "无法创建导出包检查临时目录。",
		}
	}
	inputPath := filepath.Join(inspectionDirectory, "source.zip")
	if err := os.WriteFile(inputPath, raw, 0o600); err != nil {
		_ = removeOwnedTaskDirectory(inspectionDirectory, inspectionsRoot)
		return protocol.MigrationExportInspection{}, &protocol.Error{
			Code: "inspection_staging_failed", Message: "无法暂存待检查的 Notion HTML 导出 ZIP。",
		}
	}

	command := s.runCLI(2*time.Minute, "inspect", "--input", inputPath)
	cleanupErr := removeOwnedTaskDirectory(inspectionDirectory, inspectionsRoot)
	_ = os.Remove(inspectionsRoot)
	if cleanupErr != nil {
		return protocol.MigrationExportInspection{}, &protocol.Error{
			Code: "inspection_cleanup_failed", Message: "导出包检查结束，但临时副本未能永久清理。",
		}
	}

	var payload exportInspectionPayload
	if command.exitCode != 0 || json.Unmarshal(bytes.TrimSpace(command.stdout), &payload) != nil ||
		!payload.Success || payload.InputFormat != "html" || payload.Mode != "manifest" {
		message := strings.TrimSpace(payload.Error.Message)
		if message == "" {
			message = "无法识别该导出包。请确认在 Notion 中选择了 HTML 格式。"
		}
		return protocol.MigrationExportInspection{}, &protocol.Error{
			Code: "invalid_export", Message: message,
		}
	}
	title := strings.TrimSpace(payload.Title)
	if title == "" || utf8.RuneCountInString(title) > 500 || payload.PageCount < 1 {
		return protocol.MigrationExportInspection{}, &protocol.Error{
			Code: "invalid_export_metadata", Message: "导出包缺少可确认的根页面标题或页面数量。",
		}
	}
	if _, err := time.Parse(time.RFC3339Nano, payload.ExportedAt); err != nil {
		return protocol.MigrationExportInspection{}, &protocol.Error{
			Code: "invalid_export_metadata", Message: "导出包缺少可确认的导出时间。",
		}
	}
	previousExport := findPreviousExport(s.dataDirectory, raw)
	return protocol.MigrationExportInspection{
		FileName:       strings.TrimSpace(params.FileName),
		Title:          title,
		ExportedAt:     payload.ExportedAt,
		PageCount:      payload.PageCount,
		Bytes:          len(raw),
		PreviousExport: previousExport,
	}, nil
}

func stateRecordTimestamp(record migrationStateRecord, fallback time.Time) (string, time.Time) {
	for _, value := range []string{record.CompletedAt, record.UpdatedAt, record.StartedAt} {
		value = strings.TrimSpace(value)
		if parsed, err := time.Parse(time.RFC3339Nano, value); err == nil {
			return parsed.UTC().Format(time.RFC3339Nano), parsed
		}
	}
	fallback = fallback.UTC()
	return fallback.Format(time.RFC3339Nano), fallback
}

func stateRecordDocumentURL(record migrationStateRecord) (string, string) {
	if isDingTalkDocumentURL(record.Remote.DocumentURL) {
		return record.Remote.DocumentURL, "inline"
	}
	if strings.EqualFold(record.Mode, "tree") {
		for _, page := range record.Pages {
			if strings.TrimSpace(page.ParentPageKey) == "" && isDingTalkDocumentURL(page.Remote.DocumentURL) {
				return page.Remote.DocumentURL, "tree"
			}
		}
	}
	return "", ""
}

func findPreviousExport(dataDirectory string, raw []byte) *protocol.MigrationPreviousExport {
	target, ok := readConfiguredTargetDetails(dataDirectory)
	if !ok {
		return nil
	}
	stateDirectory := filepath.Join(dataDirectory, "state", "migrations")
	entries, err := os.ReadDir(stateDirectory)
	if err != nil {
		return nil
	}
	sourceSum := sha256.Sum256(raw)
	sourceHash := hex.EncodeToString(sourceSum[:])
	byDocumentURL := make(map[string]previousExportCandidate)
	for index, entry := range entries {
		if index >= 5000 || entry.IsDir() || !strings.EqualFold(filepath.Ext(entry.Name()), ".json") {
			continue
		}
		info, infoErr := entry.Info()
		if infoErr != nil || !info.Mode().IsRegular() || info.Size() < 2 || info.Size() > 256*1024 {
			continue
		}
		content, readErr := os.ReadFile(filepath.Join(stateDirectory, entry.Name()))
		if readErr != nil {
			continue
		}
		var record migrationStateRecord
		if json.Unmarshal(content, &record) != nil ||
			!strings.EqualFold(strings.TrimSpace(record.Source.SHA256), sourceHash) ||
			!strings.EqualFold(strings.TrimSpace(record.Target.Type), target.Type) ||
			strings.TrimSpace(record.Target.ID) != target.ID {
			continue
		}
		documentURL, subpageMode := stateRecordDocumentURL(record)
		if documentURL == "" {
			continue
		}
		status := ""
		if record.Success && strings.EqualFold(record.Status, "success") {
			status = "success"
		} else if strings.EqualFold(record.Status, "unknown") {
			status = "unknown"
		}
		if status == "" {
			continue
		}
		updatedAt, updatedTime := stateRecordTimestamp(record, info.ModTime())
		candidate := previousExportCandidate{
			status: status, documentURL: documentURL, updatedAt: updatedAt,
			updatedTime: updatedTime, subpageMode: subpageMode,
		}
		previous, exists := byDocumentURL[documentURL]
		if !exists || (candidate.status == "success" && previous.status != "success") ||
			(candidate.status == previous.status && candidate.updatedTime.After(previous.updatedTime)) {
			byDocumentURL[documentURL] = candidate
		}
	}
	if len(byDocumentURL) == 0 {
		return nil
	}
	var selected previousExportCandidate
	for _, candidate := range byDocumentURL {
		if selected.documentURL == "" ||
			(candidate.status == "success" && selected.status != "success") ||
			(candidate.status == selected.status && candidate.updatedTime.After(selected.updatedTime)) {
			selected = candidate
		}
	}
	return &protocol.MigrationPreviousExport{
		Status: selected.status, DocumentURL: selected.documentURL,
		UpdatedAt: selected.updatedAt, Count: len(byDocumentURL), SubpageMode: selected.subpageMode,
	}
}

func isDingTalkDocumentURL(value string) bool {
	parsed, err := url.Parse(strings.TrimSpace(value))
	return err == nil &&
		parsed.Scheme == "https" &&
		strings.EqualFold(parsed.Hostname(), "alidocs.dingtalk.com") &&
		strings.HasPrefix(parsed.EscapedPath(), "/i/nodes/")
}

func readConfiguredTargetDetails(dataDirectory string) (configuredTarget, bool) {
	configPath := filepath.Join(dataDirectory, "config.json")
	content, err := os.ReadFile(configPath)
	if err != nil {
		return configuredTarget{}, false
	}
	var config struct {
		Folder     string `json:"folder"`
		FolderName string `json:"folderName"`
		Workspace  string `json:"workspace"`
	}
	if json.Unmarshal(content, &config) != nil {
		return configuredTarget{}, false
	}
	if strings.TrimSpace(config.Folder) != "" {
		name := strings.TrimSpace(config.FolderName)
		if name == "" {
			name = "已配置的钉钉文件夹"
		}
		return configuredTarget{Type: "folder", ID: strings.TrimSpace(config.Folder), DisplayName: name}, true
	}
	if strings.TrimSpace(config.Workspace) != "" {
		return configuredTarget{
			Type: "workspace", ID: strings.TrimSpace(config.Workspace), DisplayName: "已配置的钉钉知识库",
		}, true
	}
	return configuredTarget{}, false
}

func readConfiguredTarget(dataDirectory string) (string, string) {
	target, ok := readConfiguredTargetDetails(dataDirectory)
	if !ok {
		return "", ""
	}
	return target.Type, target.DisplayName
}

func migrationResult(payload migrationPayload, sourcePageCaptured bool) protocol.MigrationResult {
	subpageMode := "inline"
	if payload.Checks.RecursivePageCount > 0 {
		subpageMode = "tree"
	}
	return protocol.MigrationResult{
		TaskID:                    payload.TaskID,
		RemoteTaskID:              payload.Remote.TaskID,
		DocumentURL:               payload.Remote.DocumentURL,
		Reused:                    payload.Reused,
		ExpectedImageCount:        payload.Checks.ExpectedImageCount,
		ReadbackImageCount:        payload.Checks.ReadbackImageCount,
		NativeTodoCount:           payload.Checks.NativeTodoCount,
		NativeCodeBlockCount:      payload.Checks.NativeCodeBlockCount,
		NativeLayoutCount:         payload.Checks.NativeLayoutCount,
		NativeSubpageTocItemCount: payload.Checks.NativeSubpageTocItemCount,
		SubpageMode:               subpageMode,
		RecursivePageCount:        payload.Checks.RecursivePageCount,
		RecursiveFolderCount:      payload.Checks.RecursiveFolderCount,
		RecursiveLinkCount:        payload.Checks.RecursiveLinkCount,
		CleanupVerified:           payload.Cleanup.Verified,
		SourcePageCaptured:        sourcePageCaptured,
	}
}

func (s *Service) runCLI(timeout time.Duration, arguments ...string) commandResult {
	if !isFile(s.cliScript) || !isFile(s.powershell) {
		return commandResult{exitCode: -1, err: errors.New("CLI or PowerShell is unavailable")}
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	commandArguments := []string{
		"-NoProfile",
		"-ExecutionPolicy",
		"Bypass",
		"-File",
		s.cliScript,
	}
	commandArguments = append(commandArguments, arguments...)
	command := exec.CommandContext(ctx, s.powershell, commandArguments...)
	configureNoWindow(command)
	if isDirectory(s.dataDirectory) {
		command.Dir = s.dataDirectory
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	err := command.Run()
	exitCode := 0
	if err != nil {
		exitCode = -1
		var exitError *exec.ExitError
		if errors.As(err, &exitError) {
			exitCode = exitError.ExitCode()
		}
	}
	if ctx.Err() == context.DeadlineExceeded {
		err = fmt.Errorf("command timed out: %w", ctx.Err())
		exitCode = -1
	}
	return commandResult{
		stdout:   stdout.Bytes(),
		stderr:   stderr.Bytes(),
		exitCode: exitCode,
		err:      err,
	}
}

func removeOwnedTaskDirectory(taskDirectory, tasksRoot string) error {
	resolvedTask, err := filepath.Abs(taskDirectory)
	if err != nil {
		return err
	}
	resolvedRoot, err := filepath.Abs(tasksRoot)
	if err != nil {
		return err
	}
	relative, err := filepath.Rel(resolvedRoot, resolvedTask)
	if err != nil || relative == "." || relative == "" || strings.HasPrefix(relative, ".."+string(os.PathSeparator)) || filepath.IsAbs(relative) {
		return errors.New("temporary task path is outside the owned root")
	}
	if err := os.RemoveAll(resolvedTask); err != nil {
		return err
	}
	if _, err := os.Stat(resolvedTask); !errors.Is(err, os.ErrNotExist) {
		return errors.New("temporary task directory still exists")
	}
	return nil
}

func randomID() (string, error) {
	value := make([]byte, 8)
	if _, err := rand.Read(value); err != nil {
		return "", err
	}
	return hex.EncodeToString(value), nil
}

func isFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}

func isDirectory(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}
