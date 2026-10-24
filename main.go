package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/chromedp/chromedp"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
		os.Exit(1)
	}
}

func run() error {
	home, err := os.UserHomeDir()
	if err != nil {
		return fmt.Errorf("get home directory: %w", err)
	}

	defaultBookmarks := filepath.Join(
		home,
		"Library", "Application Support",
		"Microsoft Edge", "Default", "Bookmarks",
	)
	defaultEdge := "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"

	switch runtime.GOOS {
	case "windows":
		defaultBookmarks = filepath.Join(
			os.Getenv("LOCALAPPDATA"),
			"Microsoft", "Edge", "User Data", "Default", "Bookmarks",
		)
		defaultEdge = filepath.Join(
			os.Getenv("ProgramFiles(x86)"),
			"Microsoft", "Edge", "Application", "msedge.exe",
		)
	case "linux":
		defaultBookmarks = filepath.Join(
			home, ".config", "microsoft-edge", "Default", "Bookmarks",
		)
		defaultEdge = "/usr/bin/microsoft-edge"
	}

	bookmarksPath := flag.String(
		"bookmarks", defaultBookmarks,
		"Path to Edge's Bookmarks file",
	)
	edgePath := flag.String(
		"edge", defaultEdge,
		"Path to the Edge executable",
	)
	apply := flag.Bool(
		"apply", false,
		"Save changed URLs to the Bookmarks file",
	)
	waitSeconds := flag.Int(
		"wait", 3,
		"Maximum seconds to wait for JavaScript redirects (0-30)",
	)
	flag.Parse()

	if *waitSeconds < 0 || *waitSeconds > 30 {
		return errors.New("-wait must be between 0 and 30")
	}

	if _, err := os.Stat(*bookmarksPath); err != nil {
		return fmt.Errorf("cannot access bookmarks file %q: %w",
			*bookmarksPath, err)
	}

	if _, err := os.Stat(*edgePath); err != nil {
		return fmt.Errorf("cannot access Edge executable %q: %w",
			*edgePath, err)
	}

	// Edge may overwrite the Bookmarks file when it exits.
	if *apply && edgeIsRunning() {
		return errors.New(
			"close all Edge windows and background Edge processes before using -apply",
		)
	}

	data, err := os.ReadFile(*bookmarksPath)
	if err != nil {
		return fmt.Errorf("read bookmarks: %w", err)
	}

	var root map[string]any
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()

	if err := decoder.Decode(&root); err != nil {
		return fmt.Errorf("parse bookmarks JSON: %w", err)
	}

	// Walk the entire roots tree. Bookmark folders can be nested.
	var bookmarks []map[string]any

	var walk func(any)
	walk = func(value any) {
		switch node := value.(type) {
		case map[string]any:
			if node["type"] == "url" {
				if _, ok := node["url"].(string); ok {
					bookmarks = append(bookmarks, node)
				}
				return
			}

			for _, child := range node {
				walk(child)
			}

		case []any:
			for _, child := range node {
				walk(child)
			}
		}
	}

	walk(root["roots"])

	fmt.Printf("Found %d bookmarks\n", len(bookmarks))

	// Use a temporary profile to avoid interfering with the normal
	// Edge profile. This profile will not contain your Google login.
	profile, err := os.MkdirTemp("", "edge-bookmark-sync-")
	if err != nil {
		return fmt.Errorf("create temporary profile: %w", err)
	}
	defer os.RemoveAll(profile)

	opts := append(
		[]chromedp.ExecAllocatorOption{},
		chromedp.DefaultExecAllocatorOptions[:]...,
	)

	opts = append(opts,
		chromedp.ExecPath(*edgePath),
		chromedp.UserDataDir(profile),
		chromedp.Flag("headless", true),
		chromedp.Flag("disable-extensions", true),
		chromedp.Flag("no-first-run", true),
		chromedp.Flag("no-default-browser-check", true),
	)

	allocCtx, cancelAlloc := chromedp.NewExecAllocator(
		context.Background(), opts...,
	)
	defer cancelAlloc()

	browserCtx, cancelBrowser := chromedp.NewContext(allocCtx)
	defer cancelBrowser()

	if err := chromedp.Do(
		browserCtx, chromedp.Navigate("about:blank"),
	); err != nil {
		return fmt.Errorf("start Edge: %w", err)
	}

	changed := 0
	skipped := 0

	for i, bookmark := range bookmarks {
		oldURL, ok := bookmark["url"].(string)
		if !ok || !isHTTPURL(oldURL) {
			skipped++
			continue
		}

		fmt.Printf("[%d/%d] Checking %s\n", i+1, len(bookmarks), oldURL)

		tabCtx, cancelTab := chromedp.NewContext(browserCtx)

		navErr := chromedp.Do(tabCtx, chromedp.Navigate(oldURL))

		// Even if navigation reports an error, inspect the current URL.
		// JavaScript navigation can interrupt the original navigation.
		currentURL := oldURL
		deadline := time.Now().Add(time.Duration(*waitSeconds) * time.Second)

		for {
			location, locationErr := chromedp.Run(
				tabCtx, chromedp.Location(),
			)

			if locationErr == nil && location != "" {
				currentURL = location
			}

			if isLoginRedirect(currentURL) {
				break
			}

			if time.Now().After(deadline) {
				break
			}

			time.Sleep(250 * time.Millisecond)
		}

		cancelTab()

		if isLoginRedirect(currentURL) {
			fmt.Printf("  SKIP: redirected to a login page\n")
			skipped++
			continue
		}

		if !isHTTPURL(currentURL) {
			fmt.Printf("  SKIP: final URL is not HTTP(S): %s\n", currentURL)
			skipped++
			continue
		}

		if currentURL == oldURL {
			if navErr != nil {
				fmt.Printf("  WARNING: navigation error: %v\n", navErr)
			} else {
				fmt.Printf("  Unchanged\n")
			}
			continue
		}

		fmt.Printf("  OLD: %s\n", oldURL)
		fmt.Printf("  NEW: %s\n", currentURL)

		bookmark["url"] = currentURL
		changed++
	}

	fmt.Printf("\nFinished. Changed: %d, skipped: %d\n", changed, skipped)

	if changed == 0 {
		fmt.Println("No bookmark URLs need updating.")
		return nil
	}

	if !*apply {
		fmt.Println("\nDry run: no changes were saved.")
		fmt.Println("Review the URLs above, then rerun with -apply to save.")
		return nil
	}

	// Create a backup before changing the original file.
	backupPath := *bookmarksPath + "." +
		time.Now().Format("20060102-150405") + ".bak"

	if err := copyFile(*bookmarksPath, backupPath); err != nil {
		return fmt.Errorf("create backup: %w", err)
	}
	fmt.Printf("Backup created: %s\n", backupPath)

	output, err := json.MarshalIndent(root, "", "    ")
	if err != nil {
		return fmt.Errorf("encode bookmarks JSON: %w", err)
	}
	output = append(output, '\n')

	info, err := os.Stat(*bookmarksPath)
	if err != nil {
		return fmt.Errorf("stat bookmarks: %w", err)
	}

	// Write a temporary file in the same directory for an atomic rename.
	dir := filepath.Dir(*bookmarksPath)
	tempFile, err := os.CreateTemp(dir, ".Bookmarks-*.tmp")
	if err != nil {
		return fmt.Errorf("create temporary output: %w", err)
	}

	tempPath := tempFile.Name()
	defer os.Remove(tempPath)

	if _, err := tempFile.Write(output); err != nil {
		tempFile.Close()
		return fmt.Errorf("write temporary output: %w", err)
	}

	if err := tempFile.Chmod(info.Mode().Perm()); err != nil {
		tempFile.Close()
		return fmt.Errorf("preserve file permissions: %w", err)
	}

	if err := tempFile.Close(); err != nil {
		return fmt.Errorf("close temporary output: %w", err)
	}

	if err := os.Rename(tempPath, *bookmarksPath); err != nil {
		return fmt.Errorf("replace bookmarks file: %w", err)
	}

	fmt.Printf("Successfully updated %d bookmark URLs.\n", changed)
	fmt.Println("Restart Edge if needed to see the changes.")

	return nil
}

// isLoginRedirect prevents login pages from being saved as destination URLs.
func isLoginRedirect(rawURL string) bool {
	u, err := url.Parse(rawURL)
	if err != nil {
		return false
	}

	host := strings.ToLower(u.Hostname())
	path := strings.ToLower(u.Path)

	return host == "accounts.google.com" ||
		strings.Contains(path, "/login") ||
		strings.Contains(path, "/signin")
}

func isHTTPURL(rawURL string) bool {
	u, err := url.Parse(rawURL)
	if err != nil {
		return false
	}

	return (u.Scheme == "http" || u.Scheme == "https") &&
		u.Hostname() != ""
}

func copyFile(src, dst string) error {
	input, err := os.ReadFile(src)
	if err != nil {
		return err
	}

	info, err := os.Stat(src)
	if err != nil {
		return err
	}

	if err := os.WriteFile(dst, input, info.Mode().Perm()); err != nil {
		return err
	}

	return nil
}

func edgeIsRunning() bool {
	switch runtime.GOOS {
	case "windows":
		output, err := exec.Command(
			"tasklist", "/FI", "IMAGENAME eq msedge.exe",
		).Output()
		if err != nil {
			return false
		}
		return strings.Contains(
			strings.ToLower(string(output)), "msedge.exe",
		)

	case "darwin":
		err := exec.Command(
			"pgrep", "-x", "Microsoft Edge",
		).Run()
		return err == nil

	default:
		err := exec.Command(
			"pgrep", "-x", "microsoft-edge",
		).Run()
		if err == nil {
			return true
		}

		err = exec.Command(
			"pgrep", "-x", "msedge",
		).Run()
		return err == nil
	}
}
