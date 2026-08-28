//go:build windows

package localtool

import (
	"os/exec"
	"strconv"
)

func terminateProcessTree(command *exec.Cmd) {
	if command == nil || command.Process == nil {
		return
	}
	killer := exec.Command(
		"taskkill.exe",
		"/PID", strconv.Itoa(command.Process.Pid),
		"/T",
		"/F",
	)
	configureNoWindow(killer)
	_ = killer.Run()
	_ = command.Process.Kill()
}
