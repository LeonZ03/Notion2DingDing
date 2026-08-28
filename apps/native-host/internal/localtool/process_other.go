//go:build !windows

package localtool

import "os/exec"

func configureNoWindow(_ *exec.Cmd) {}

func configureDetachedWindow(_ *exec.Cmd) {}
