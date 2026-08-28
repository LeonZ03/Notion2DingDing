//go:build windows

package localtool

import (
	"os/exec"
	"syscall"
)

const (
	createBreakawayFromJob = 0x01000000
	createNoWindow         = 0x08000000
)

func configureNoWindow(command *exec.Cmd) {
	command.SysProcAttr = &syscall.SysProcAttr{
		HideWindow:    true,
		CreationFlags: createNoWindow,
	}
}

func configureDetachedWindow(command *exec.Cmd) {
	command.SysProcAttr = &syscall.SysProcAttr{
		HideWindow:    true,
		CreationFlags: createNoWindow | createBreakawayFromJob,
	}
}
