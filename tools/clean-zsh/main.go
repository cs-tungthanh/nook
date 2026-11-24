package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
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

// groupEntries joins the physical lines of the history file into entries.
// Zsh saves a multi-line command as lines ending in a backslash, so a line
// ending in an odd number of backslashes continues on the next line.
func groupEntries(lines []string) []string {
	var entries []string
	var current []string
	for _, line := range lines {
		current = append(current, line)
		if !continues(line) {
			entries = append(entries, strings.Join(current, "\n"))
			current = nil
		}
	}
	if len(current) > 0 {
		entries = append(entries, strings.Join(current, "\n"))
	}
	return entries
}

func continues(line string) bool {
	n := 0
	for i := len(line) - 1; i >= 0 && line[i] == '\\'; i-- {
		n++
	}
	return n%2 == 1
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

	// Hold zsh's own history lock so a shell can't append between the read
	// and the rename; those entries would be lost.
	unlock, err := lockHistory(histFile)
	if err != nil {
		panic(err)
	}
	defer unlock()

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

	entries := groupEntries(lines)

	last := make(map[string]int, len(entries))
	for i, entry := range entries {
		last[commandOf(entry)] = i
	}

	// Keep only the latest occurrence, preserving order.
	var cleaned []string
	for i, entry := range entries {
		if last[commandOf(entry)] == i {
			cleaned = append(cleaned, entry)
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

	fmt.Printf("Original entries: %d\n", len(entries))
	fmt.Printf("Remaining entries: %d\n", len(cleaned))
	fmt.Printf("Removed duplicates: %d\n", len(entries)-len(cleaned))
	fmt.Printf("Backup: %s\n", backup)
}

// lockHistory takes the HISTFILE.LOCK file zsh uses (with the default
// HIST_FCNTL_LOCK unset), waiting a few seconds for a shell holding it.
func lockHistory(histFile string) (func(), error) {
	lock := histFile + ".LOCK"
	deadline := time.Now().Add(5 * time.Second)
	for {
		f, err := os.OpenFile(lock, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		if err == nil {
			f.Close()
			return func() { os.Remove(lock) }, nil
		}
		if !os.IsExist(err) {
			return nil, err
		}
		if time.Now().After(deadline) {
			return nil, fmt.Errorf("%s is held by another shell; try again, or remove it if no shell is writing history", lock)
		}
		time.Sleep(100 * time.Millisecond)
	}
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
