//go:build windows

package localtool

import (
	"os/exec"
	"testing"
)

func TestConfigureDetachedWindowBreaksAwayFromBrowserJob(t *testing.T) {
	command := exec.Command("powershell.exe")
	configureDetachedWindow(command)
	if command.SysProcAttr == nil {
		t.Fatal("expected Windows process attributes")
	}
	flags := command.SysProcAttr.CreationFlags
	if flags&createBreakawayFromJob == 0 {
		t.Fatalf("detached settings process must break away from the Edge Native Host job: %#x", flags)
	}
	if flags&createNoWindow == 0 || !command.SysProcAttr.HideWindow {
		t.Fatalf("detached settings process must keep the console hidden: %#x", flags)
	}
}
