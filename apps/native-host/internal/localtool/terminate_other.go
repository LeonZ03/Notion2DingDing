//go:build !windows

package localtool

import "os/exec"

func terminateProcessTree(command *exec.Cmd) {
	if command == nil || command.Process == nil {
		return
	}
	_ = command.Process.Kill()
}
