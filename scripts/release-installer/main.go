package main

import (
	"archive/zip"
	"bufio"
	"bytes"
	_ "embed"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// payload.zip is generated in an isolated build directory by build-release.ps1.
//
//go:embed payload.zip
var payload []byte

func extractPayload(root string) error {
	reader, err := zip.NewReader(bytes.NewReader(payload), int64(len(payload)))
	if err != nil {
		return fmt.Errorf("安装包内容损坏：%w", err)
	}
	prefix := filepath.Clean(root) + string(os.PathSeparator)
	for _, file := range reader.File {
		target := filepath.Join(root, filepath.FromSlash(file.Name))
		cleanTarget := filepath.Clean(target)
		if !strings.HasPrefix(cleanTarget, prefix) {
			return fmt.Errorf("安装包包含不安全路径：%s", file.Name)
		}
		if file.FileInfo().IsDir() {
			if err := os.MkdirAll(cleanTarget, 0o755); err != nil {
				return err
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(cleanTarget), 0o755); err != nil {
			return err
		}
		source, err := file.Open()
		if err != nil {
			return err
		}
		destination, err := os.OpenFile(cleanTarget, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, file.Mode())
		if err != nil {
			source.Close()
			return err
		}
		_, copyErr := io.Copy(destination, source)
		closeDestinationErr := destination.Close()
		closeSourceErr := source.Close()
		if copyErr != nil {
			return copyErr
		}
		if closeDestinationErr != nil {
			return closeDestinationErr
		}
		if closeSourceErr != nil {
			return closeSourceErr
		}
	}
	return nil
}

func main() {
	pause := true
	forwarded := make([]string, 0, len(os.Args))
	for _, argument := range os.Args[1:] {
		if argument == "--no-pause" {
			pause = false
			continue
		}
		forwarded = append(forwarded, argument)
	}

	workingDirectory, err := os.MkdirTemp("", "notion2dingding-setup-")
	if err != nil {
		fmt.Fprintf(os.Stderr, "无法创建安装临时目录：%v\n", err)
		os.Exit(1)
	}
	defer os.RemoveAll(workingDirectory)

	if err := extractPayload(workingDirectory); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	systemRoot := os.Getenv("SystemRoot")
	if systemRoot == "" {
		fmt.Fprintln(os.Stderr, "无法读取 Windows SystemRoot。")
		os.Exit(1)
	}
	powershell := filepath.Join(systemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
	installer := filepath.Join(workingDirectory, "scripts", "install-release.ps1")
	arguments := []string{"-NoProfile", "-ExecutionPolicy", "Bypass", "-File", installer}
	arguments = append(arguments, forwarded...)
	command := exec.Command(powershell, arguments...)
	command.Dir = workingDirectory
	command.Stdin = os.Stdin
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	err = command.Run()
	if err != nil {
		fmt.Fprintf(os.Stderr, "安装未完成：%v\n", err)
	}
	if pause {
		fmt.Println()
		fmt.Println("按 Enter 关闭安装窗口…")
		_, _ = bufio.NewReader(os.Stdin).ReadString('\n')
	}
	if err != nil {
		os.Exit(1)
	}
}
