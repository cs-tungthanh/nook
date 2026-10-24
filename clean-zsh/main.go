package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

func commandOf(line string) string {
	// Extended Zsh history format:
	// : timestamp:duration;command
	if strings.HasPrefix(line, ": ") {
		if i := strings.IndexByte(line, ';'); i >= 0 {
			return line[i+1:]
		}
	}
	return line
}

func main() {
	home, err := os.UserHomeDir()
	if err != nil {
		panic(err)
	}

	histFile := filepath.Join(home, ".zsh_history")
	if len(os.Args) > 1 {
		histFile = os.Args[1]
	}

	file, err := os.Open(histFile)
	if err != nil {
		panic(err)
	}

	var lines []string
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 64*1024), 10*1024*1024)

	for scanner.Scan() {
		lines = append(lines, scanner.Text())
	}
	scanErr := scanner.Err()
	closeErr := file.Close()
	if scanErr != nil {
		panic(scanErr)
	}
	if closeErr != nil {
		panic(closeErr)
	}

	// Record the last occurrence of each command.
	last := make(map[string]int, len(lines))
	for i, line := range lines {
		last[commandOf(line)] = i
	}

	// Keep only the latest occurrence, preserving order.
	var cleaned []string
	for i, line := range lines {
		if last[commandOf(line)] == i {
			cleaned = append(cleaned, line)
		}
	}

	backup := histFile + ".bak"
	if err := copyFile(histFile, backup); err != nil {
		panic(err)
	}

	tmp := histFile + ".tmp"
	out, err := os.Create(tmp)
	if err != nil {
		panic(err)
	}

	writer := bufio.NewWriter(out)
	for _, line := range cleaned {
		if _, err := writer.WriteString(line + "\n"); err != nil {
			out.Close()
			os.Remove(tmp)
			panic(err)
		}
	}
	if err := writer.Flush(); err != nil {
		out.Close()
		os.Remove(tmp)
		panic(err)
	}
	if err := out.Close(); err != nil {
		os.Remove(tmp)
		panic(err)
	}

	if err := os.Chmod(tmp, 0600); err != nil {
		os.Remove(tmp)
		panic(err)
	}
	if err := os.Rename(tmp, histFile); err != nil {
		os.Remove(tmp)
		panic(err)
	}

	fmt.Printf("Original entries: %d\n", len(lines))
	fmt.Printf("Remaining entries: %d\n", len(cleaned))
	fmt.Printf("Removed duplicates: %d\n", len(lines)-len(cleaned))
	fmt.Printf("Backup: %s\n", backup)
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	out, err := os.OpenFile(dst, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}

	_, copyErr := out.ReadFrom(in)
	closeErr := out.Close()
	if copyErr != nil {
		return copyErr
	}
	return closeErr
}
