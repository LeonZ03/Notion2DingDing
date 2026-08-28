package localtool

import (
	"bufio"
	"bytes"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/LeonZ03/Notion2DingDing/apps/native-host/internal/protocol"
)

var progressLinePattern = regexp.MustCompile(`^\[(\d+)/(\d+)\]\s*(.+)$`)

type migrationTask struct {
	mu              sync.Mutex
	snapshot        protocol.MigrationTaskSnapshot
	command         *exec.Cmd
	taskDirectory   string
	done            chan struct{}
	cancelRequested bool
	timedOut        bool
}

func (task *migrationTask) copySnapshot() protocol.MigrationTaskSnapshot {
	task.mu.Lock()
	defer task.mu.Unlock()
	value := task.snapshot
	if task.snapshot.Result != nil {
		result := *task.snapshot.Result
		value.Result = &result
	}
	if task.snapshot.Error != nil {
		failure := *task.snapshot.Error
		if task.snapshot.Error.Details != nil {
			failure.Details = make(map[string]any, len(task.snapshot.Error.Details))
			for key, item := range task.snapshot.Error.Details {
				failure.Details[key] = item
			}
		}
		value.Error = &failure
	}
	return value
}

func (task *migrationTask) updateProgress(current, total int, stage, message string) {
	task.mu.Lock()
	defer task.mu.Unlock()
	if current > task.snapshot.Progress.Current {
		task.snapshot.Progress.Current = current
	}
	if total > 0 {
		task.snapshot.Progress.Total = total
	}
	percent := 0
	if total > 0 {
		percent = current * 90 / total
	}
	if percent > task.snapshot.Progress.Percent {
		task.snapshot.Progress.Percent = percent
	}
	if strings.TrimSpace(stage) != "" {
		task.snapshot.Progress.Stage = stage
	}
	if strings.TrimSpace(message) != "" {
		task.snapshot.Progress.Message = strings.TrimSpace(message)
	}
	// 钉钉写入开始后终止本地进程可能留下无法确认的远端文档，因而只允许在预检和转换阶段取消。
	if current >= 3 {
		task.snapshot.CanCancel = false
	}
	task.snapshot.UpdatedAt = time.Now().UTC().Format(time.RFC3339Nano)
}

func (task *migrationTask) setCommand(command *exec.Cmd) bool {
	task.mu.Lock()
	defer task.mu.Unlock()
	task.command = command
	return task.cancelRequested
}

func (task *migrationTask) cancellationState() (bool, bool) {
	task.mu.Lock()
	defer task.mu.Unlock()
	return task.cancelRequested, task.timedOut
}

func (task *migrationTask) finish(
	status string,
	result *protocol.MigrationResult,
	failure *protocol.Error,
	recoveryAction string,
	message string,
) {
	task.mu.Lock()
	defer task.mu.Unlock()
	task.snapshot.Status = status
	task.snapshot.CanCancel = false
	task.snapshot.RecoveryAction = recoveryAction
	task.snapshot.Result = result
	task.snapshot.Error = failure
	task.snapshot.Progress.Stage = status
	task.snapshot.Progress.Message = message
	if status == "succeeded" {
		task.snapshot.Progress.Current = task.snapshot.Progress.Total
		task.snapshot.Progress.Percent = 100
	}
	task.snapshot.UpdatedAt = time.Now().UTC().Format(time.RFC3339Nano)
}

func (s *Service) StartMigration(params protocol.MigrationExportParams) (
	protocol.MigrationTaskSnapshot,
	*protocol.Error,
) {
	raw, validationFailure := validateExport(params)
	if validationFailure != nil {
		return protocol.MigrationTaskSnapshot{}, validationFailure
	}
	if !isFile(s.cliScript) {
		return protocol.MigrationTaskSnapshot{}, &protocol.Error{
			Code:    "local_tool_not_installed",
			Message: "未找到已安装的 Notion2DingDing 本地工具。",
		}
	}
	if strings.TrimSpace(s.dataDirectory) == "" {
		return protocol.MigrationTaskSnapshot{}, &protocol.Error{
			Code:    "data_directory_unavailable",
			Message: "无法确定本地工具数据目录。",
		}
	}

	s.tasksMu.Lock()
	if s.closing {
		s.tasksMu.Unlock()
		return protocol.MigrationTaskSnapshot{}, &protocol.Error{
			Code:    "native_host_closing",
			Message: "本地助手正在关闭，请重新打开扩展后再试。",
		}
	}
	for _, existing := range s.tasks {
		snapshot := existing.copySnapshot()
		if snapshot.Status == "queued" || snapshot.Status == "running" || snapshot.Status == "cancel_requested" {
			s.tasksMu.Unlock()
			return protocol.MigrationTaskSnapshot{}, &protocol.Error{
				Code:    "migration_already_running",
				Message: "已有迁移任务正在运行，请等待完成或先取消。",
				Details: map[string]any{"taskId": snapshot.TaskID},
			}
		}
	}
	s.tasksMu.Unlock()

	tasksRoot := filepath.Join(s.dataDirectory, "native-host", "tasks")
	if err := os.MkdirAll(tasksRoot, 0o700); err != nil {
		return protocol.MigrationTaskSnapshot{}, &protocol.Error{
			Code:    "staging_failed",
			Message: "无法创建 Native Host 临时任务目录。",
		}
	}
	taskID, err := randomID()
	if err != nil {
		return protocol.MigrationTaskSnapshot{}, &protocol.Error{
			Code: "staging_failed", Message: "无法创建安全临时任务标识。",
		}
	}
	taskDirectory, err := os.MkdirTemp(tasksRoot, "task-"+taskID+"-")
	if err != nil {
		return protocol.MigrationTaskSnapshot{}, &protocol.Error{
			Code: "staging_failed", Message: "无法创建 Native Host 临时任务目录。",
		}
	}
	inputPath := filepath.Join(taskDirectory, "source.zip")
	if err := os.WriteFile(inputPath, raw, 0o600); err != nil {
		_ = removeOwnedTaskDirectory(taskDirectory, tasksRoot)
		return protocol.MigrationTaskSnapshot{}, &protocol.Error{
			Code: "staging_failed", Message: "无法暂存 Notion HTML 导出 ZIP。",
		}
	}

	now := time.Now().UTC().Format(time.RFC3339Nano)
	task := &migrationTask{
		taskDirectory: taskDirectory,
		done:          make(chan struct{}),
		snapshot: protocol.MigrationTaskSnapshot{
			TaskID:    taskID,
			Status:    "queued",
			CanCancel: true,
			UpdatedAt: now,
			Progress: protocol.MigrationTaskProgress{
				Current: 0,
				Total:   5,
				Percent: 0,
				Stage:   "queued",
				Message: "导出包已安全暂存，正在启动本地迁移核心。",
			},
		},
	}

	s.tasksMu.Lock()
	if s.closing {
		s.tasksMu.Unlock()
		_ = removeOwnedTaskDirectory(taskDirectory, tasksRoot)
		return protocol.MigrationTaskSnapshot{}, &protocol.Error{
			Code: "native_host_closing", Message: "本地助手正在关闭，请重新打开扩展后再试。",
		}
	}
	s.tasks[taskID] = task
	s.tasksWG.Add(1)
	s.tasksMu.Unlock()

	go s.runMigrationTask(task, params, inputPath, tasksRoot)
	return task.copySnapshot(), nil
}

func (s *Service) MigrationStatus(taskID string) (protocol.MigrationTaskSnapshot, *protocol.Error) {
	task, failure := s.findTask(taskID)
	if failure != nil {
		return protocol.MigrationTaskSnapshot{}, failure
	}
	return task.copySnapshot(), nil
}

func (s *Service) CancelMigration(taskID string) (protocol.MigrationTaskSnapshot, *protocol.Error) {
	task, failure := s.findTask(taskID)
	if failure != nil {
		return protocol.MigrationTaskSnapshot{}, failure
	}
	task.mu.Lock()
	switch task.snapshot.Status {
	case "succeeded", "failed", "unknown", "cancelled", "cancel_requested":
		snapshot := task.snapshot
		task.mu.Unlock()
		return snapshot, nil
	}
	if !task.snapshot.CanCancel {
		task.snapshot.Progress.Message = "钉钉写入已经开始，不能再安全取消；请等待导入与回读完成。"
		task.snapshot.UpdatedAt = time.Now().UTC().Format(time.RFC3339Nano)
		snapshot := task.snapshot
		task.mu.Unlock()
		return snapshot, nil
	}
	task.cancelRequested = true
	task.snapshot.Status = "cancel_requested"
	task.snapshot.CanCancel = false
	task.snapshot.Progress.Message = "正在停止本地迁移并清理临时数据…"
	task.snapshot.UpdatedAt = time.Now().UTC().Format(time.RFC3339Nano)
	command := task.command
	task.mu.Unlock()
	if command != nil {
		terminateProcessTree(command)
	}
	return task.copySnapshot(), nil
}

func (s *Service) findTask(taskID string) (*migrationTask, *protocol.Error) {
	taskID = strings.TrimSpace(taskID)
	if len(taskID) != 16 {
		return nil, &protocol.Error{Code: "invalid_task_id", Message: "迁移任务 ID 无效。"}
	}
	if _, err := hex.DecodeString(taskID); err != nil {
		return nil, &protocol.Error{Code: "invalid_task_id", Message: "迁移任务 ID 无效。"}
	}
	s.tasksMu.Lock()
	task := s.tasks[taskID]
	s.tasksMu.Unlock()
	if task == nil {
		return nil, &protocol.Error{
			Code:    "task_not_found",
			Message: "未找到该迁移任务；Native Host 可能已经重启，请重新选择导出包。",
		}
	}
	return task, nil
}

func (s *Service) runMigrationTask(
	task *migrationTask,
	params protocol.MigrationExportParams,
	inputPath string,
	tasksRoot string,
) {
	defer s.tasksWG.Done()
	defer close(task.done)

	task.mu.Lock()
	if task.cancelRequested {
		task.mu.Unlock()
		s.finishCancelledTask(task, tasksRoot)
		return
	}
	task.snapshot.Status = "running"
	task.snapshot.Progress.Stage = "preflight"
	task.snapshot.Progress.Message = "正在检查环境、登录状态和导出包…"
	task.snapshot.Progress.Percent = 3
	task.snapshot.UpdatedAt = time.Now().UTC().Format(time.RFC3339Nano)
	task.mu.Unlock()

	arguments := []string{
		"-NoProfile",
		"-ExecutionPolicy", "Bypass",
		"-File", s.cliScript,
		"migrate", "--input", inputPath,
	}
	if strings.TrimSpace(params.Title) != "" {
		arguments = append(arguments, "--name", strings.TrimSpace(params.Title))
	}
	if params.SubpageMode == "tree" {
		arguments = append(arguments, "--subpages", "tree")
	}
	if params.CreateNew {
		arguments = append(arguments, "--force")
	}
	command := exec.Command(s.powershell, arguments...)
	configureNoWindow(command)
	if isDirectory(s.dataDirectory) {
		command.Dir = s.dataDirectory
	}
	command.Env = append(
		os.Environ(),
		"N2DD_TEMP_DIRECTORY="+filepath.Join(task.taskDirectory, "core-temp"),
	)
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	command.Stdout = &stdout
	stderrPipe, pipeErr := command.StderrPipe()
	if pipeErr != nil {
		s.finishFailedTask(task, tasksRoot, nil, &protocol.Error{
			Code: "migration_start_failed", Message: "无法读取本地迁移进度。",
		}, "retry")
		return
	}
	if err := command.Start(); err != nil {
		s.finishFailedTask(task, tasksRoot, nil, &protocol.Error{
			Code: "migration_start_failed", Message: "无法启动本地迁移核心。",
		}, "retry")
		return
	}
	if task.setCommand(command) {
		terminateProcessTree(command)
	}

	scannerDone := make(chan struct{})
	go func() {
		defer close(scannerDone)
		scanner := bufio.NewScanner(stderrPipe)
		scanner.Buffer(make([]byte, 4096), 1024*1024)
		for scanner.Scan() {
			line := scanner.Text()
			if stderr.Len() < 4096 {
				_, _ = stderr.WriteString(line + "\n")
			}
			s.updateTaskProgressFromLine(task, line)
		}
	}()

	timeout := time.AfterFunc(commandTimeout, func() {
		task.mu.Lock()
		if task.snapshot.Status == "running" {
			task.timedOut = true
			task.snapshot.Progress.Message = "迁移超过 30 分钟，正在停止并清理…"
			task.snapshot.UpdatedAt = time.Now().UTC().Format(time.RFC3339Nano)
		}
		task.mu.Unlock()
		terminateProcessTree(command)
	})
	waitErr := command.Wait()
	timeout.Stop()
	<-scannerDone

	cancelled, timedOut := task.cancellationState()
	if cancelled {
		s.finishCancelledTask(task, tasksRoot)
		return
	}
	if timedOut {
		s.finishFailedTask(task, tasksRoot, nil, &protocol.Error{
			Code: "migration_timeout", Message: "迁移超过 30 分钟，已停止并清理临时数据。",
		}, "retry")
		return
	}

	var payload migrationPayload
	parseErr := json.Unmarshal(bytes.TrimSpace(stdout.Bytes()), &payload)
	if parseErr != nil {
		prefix := stdout.Bytes()
		if len(prefix) > 16 {
			prefix = prefix[:16]
		}
		s.finishFailedTask(task, tasksRoot, nil, &protocol.Error{
			Code:    "migration_invalid_response",
			Message: "本地迁移核心没有返回可解析的结果。",
			Details: map[string]any{
				"stdoutBytes":     stdout.Len(),
				"stdoutPrefixHex": hex.EncodeToString(prefix),
				"stderrBytes":     stderr.Len(),
				"stderrPrefixHex": hex.EncodeToString(stderr.Bytes()),
			},
		}, "retry")
		return
	}

	result := migrationResult(payload, params.SourcePage != nil)
	if waitErr != nil || !payload.Success {
		code := strings.TrimSpace(payload.Error.Code)
		if code == "" {
			code = "migration_failed"
		}
		message := strings.TrimSpace(payload.Error.Message)
		if message == "" {
			message = "本地迁移未完成，请按提示修复后重试。"
		}
		failure := &protocol.Error{
			Code:    code,
			Message: message,
			Details: map[string]any{
				"status":      payload.Status,
				"stage":       payload.Stage,
				"taskId":      payload.TaskID,
				"documentUrl": payload.Remote.DocumentURL,
			},
		}
		status := "failed"
		if strings.EqualFold(payload.Status, "unknown") {
			status = "unknown"
		}
		s.finishFailedTask(task, tasksRoot, &result, failure, recoveryActionForFailure(code, status))
		return
	}
	if !isDingTalkDocumentURL(result.DocumentURL) || !result.CleanupVerified {
		s.finishFailedTask(task, tasksRoot, &result, &protocol.Error{
			Code:    "migration_verification_failed",
			Message: "迁移结果缺少文档链接或清理确认，不能报告成功。",
			Details: map[string]any{
				"taskId":      result.TaskID,
				"documentUrl": result.DocumentURL,
			},
		}, "recover")
		return
	}

	if cleanupErr := removeOwnedTaskDirectory(task.taskDirectory, tasksRoot); cleanupErr != nil {
		task.finish("failed", &result, &protocol.Error{
			Code:    "native_staging_cleanup_failed",
			Message: "迁移结束，但 Native Host 未能永久清理导出包副本。",
			Details: map[string]any{"documentUrl": result.DocumentURL, "taskId": result.TaskID},
		}, "recover", "远端文档已创建，但本地临时数据清理失败。")
		return
	}
	task.finish("succeeded", &result, nil, "", "迁移、回读和临时数据清理全部完成。")
}

func (s *Service) updateTaskProgressFromLine(task *migrationTask, line string) {
	match := progressLinePattern.FindStringSubmatch(strings.TrimSpace(line))
	if len(match) != 4 {
		return
	}
	current, currentErr := strconv.Atoi(match[1])
	total, totalErr := strconv.Atoi(match[2])
	if currentErr != nil || totalErr != nil || current < 0 || total <= 0 {
		return
	}
	stage := fmt.Sprintf("step-%d", current)
	if current == 1 {
		stage = "preflight"
	} else if current == 2 {
		stage = "convert"
	} else if current == 3 {
		stage = "import"
	} else if current == 4 {
		stage = "verify"
	} else if current >= total {
		stage = "cleanup"
	}
	task.updateProgress(current, total, stage, match[3])
}

func (s *Service) finishCancelledTask(task *migrationTask, tasksRoot string) {
	cleanupErr := removeOwnedTaskDirectory(task.taskDirectory, tasksRoot)
	if cleanupErr != nil {
		task.finish("failed", nil, &protocol.Error{
			Code:    "native_staging_cleanup_failed",
			Message: "任务已停止，但 Native Host 未能永久清理临时数据。",
		}, "recover", "任务已停止，但临时数据清理失败。")
		return
	}
	task.finish("cancelled", nil, &protocol.Error{
		Code: "migration_cancelled", Message: "迁移已由用户取消，临时数据已永久清理。",
	}, "retry", "迁移已取消，未报告任何半成品为成功。")
}

func (s *Service) finishFailedTask(
	task *migrationTask,
	tasksRoot string,
	result *protocol.MigrationResult,
	failure *protocol.Error,
	recoveryAction string,
) {
	cleanupErr := removeOwnedTaskDirectory(task.taskDirectory, tasksRoot)
	if cleanupErr != nil {
		failure = &protocol.Error{
			Code:    "native_staging_cleanup_failed",
			Message: "迁移未完成，且 Native Host 未能永久清理临时数据。",
			Details: map[string]any{"previousError": failure.Code},
		}
		recoveryAction = "recover"
	}
	status := "failed"
	if strings.EqualFold(fmt.Sprint(failure.Details["status"]), "unknown") {
		status = "unknown"
	}
	task.finish(status, result, failure, recoveryAction, failure.Message)
}

func recoveryActionForFailure(code, status string) string {
	if status == "unknown" {
		return "recover"
	}
	switch code {
	case "DWS_NOT_AUTHENTICATED", "dws_not_authenticated":
		return "login"
	case "TARGET_REQUIRED", "TARGET_CONFLICT", "TREE_TARGET_FOLDER_UNRESOLVED", "target_required":
		return "target"
	case "invalid_export", "export_too_large", "invalid_page_snapshot":
		return "select_export"
	default:
		return "retry"
	}
}

func (s *Service) Shutdown() {
	s.tasksMu.Lock()
	if s.closing {
		s.tasksMu.Unlock()
		return
	}
	s.closing = true
	tasks := make([]*migrationTask, 0, len(s.tasks))
	for _, task := range s.tasks {
		tasks = append(tasks, task)
	}
	s.tasksMu.Unlock()

	for _, task := range tasks {
		snapshot := task.copySnapshot()
		if snapshot.CanCancel {
			_, _ = s.CancelMigration(snapshot.TaskID)
		}
	}
	done := make(chan struct{})
	go func() {
		s.tasksWG.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(15 * time.Second):
	}
}

func (s *Service) MigrateExport(params protocol.MigrationExportParams) (
	protocol.MigrationResult,
	*protocol.Error,
) {
	snapshot, failure := s.StartMigration(params)
	if failure != nil {
		return protocol.MigrationResult{}, failure
	}
	task, failure := s.findTask(snapshot.TaskID)
	if failure != nil {
		return protocol.MigrationResult{}, failure
	}
	<-task.done
	final := task.copySnapshot()
	if final.Status == "succeeded" && final.Result != nil {
		return *final.Result, nil
	}
	if final.Error != nil {
		if final.Result != nil {
			return *final.Result, final.Error
		}
		return protocol.MigrationResult{}, final.Error
	}
	return protocol.MigrationResult{}, &protocol.Error{
		Code: "migration_failed", Message: "迁移任务没有返回最终结果。",
	}
}
