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
	"sync"
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
	timeoutSeconds := flag.Int(
		"timeout", 20,
		"Maximum seconds to spend on one bookmark before giving up",
	)
	workers := flag.Int(
		"workers", 20,
		"Number of bookmarks to check at the same time (1-32)",
	)
	flag.Parse()

	if *workers < 1 || *workers > 32 {
		return errors.New("-workers must be between 1 and 32")
	}

	if *waitSeconds < 0 || *waitSeconds > 30 {
		return errors.New("-wait must be between 0 and 30")
	}

	if *timeoutSeconds <= *waitSeconds {
		return errors.New("-timeout must be greater than -wait")
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

	results := make([]bookmarkResult, len(bookmarks))
	jobs := make(chan int)

	var (
		wg   sync.WaitGroup
		mu   sync.Mutex
		done int
	)

	fmt.Printf("Checking with %d workers at a time\n", min(*workers, len(bookmarks)))

	for range *workers {
		wg.Add(1)
		go func() {
			defer wg.Done()

			for i := range jobs {
				oldURL := bookmarks[i]["url"].(string)

				mu.Lock()
				fmt.Printf("  checking: %s\n", oldURL)
				mu.Unlock()

				res := checkBookmark(browserCtx, oldURL, *waitSeconds, *timeoutSeconds)
				results[i] = res

				mu.Lock()
				done++
				fmt.Printf("[%d/%d] %s\n%s", done, len(bookmarks), oldURL, res.report)
				mu.Unlock()
			}
		}()
	}

	for i := range bookmarks {
		jobs <- i
	}
	close(jobs)
	wg.Wait()

	changed := 0
	skipped := 0

	for i, res := range results {
		switch {
		case res.skip:
			skipped++
		case res.newURL != "":
			bookmarks[i]["url"] = res.newURL
			changed++
		}
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

	// The checksum covers every URL, so it is stale now. Edge accepts a
	// file without one and writes a fresh checksum on its next save.
	delete(root, "checksum")

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

type bookmarkResult struct {
	newURL string // empty when the bookmark keeps its URL
	report string
	skip   bool
}

// checkBookmark opens rawURL in a new tab and reports where it ends up.
func checkBookmark(browserCtx context.Context, oldURL string, waitSeconds, timeoutSeconds int) bookmarkResult {
	if !isHTTPURL(oldURL) {
		return bookmarkResult{report: "  SKIP: not an HTTP(S) URL\n", skip: true}
	}

	tabCtx, cancelTab := chromedp.NewContext(browserCtx)
	defer cancelTab()

	// Open the tab before adding timeouts. The tab's event loop runs on the
	// context of its first call, so a cancelled timeout context would stop
	// it and leave every later call waiting forever.
	if err := chromedp.Do(tabCtx); err != nil {
		return bookmarkResult{report: fmt.Sprintf("  WARNING: cannot open tab: %v\n", err)}
	}

	// A slow or hanging site must not block the remaining bookmarks.
	// Every call below, including reading the location, shares this limit.
	ctx, cancel := context.WithTimeout(
		tabCtx, time.Duration(timeoutSeconds)*time.Second,
	)
	defer cancel()

	navCtx, cancelNav := context.WithTimeout(
		ctx, time.Duration(timeoutSeconds-waitSeconds)*time.Second,
	)
	navErr := chromedp.Do(navCtx, chromedp.Navigate(oldURL))
	cancelNav()

	// Even if navigation reports an error, inspect the current URL.
	// JavaScript navigation can interrupt the original navigation.
	currentURL := oldURL
	deadline := time.Now().Add(time.Duration(waitSeconds) * time.Second)

	for {
		location, locationErr := chromedp.Run(ctx, chromedp.Location())

		if locationErr == nil && location != "" {
			currentURL = location
		}

		if isLoginRedirect(currentURL) {
			break
		}

		if ctx.Err() != nil || time.Now().After(deadline) {
			break
		}

		time.Sleep(250 * time.Millisecond)
	}

	if isLoginRedirect(currentURL) {
		return bookmarkResult{
			report: fmt.Sprintf("  SKIP: redirected to a login page: %s\n", currentURL),
			skip:   true,
		}
	}

	if isChallengePage(currentURL) {
		return bookmarkResult{
			report: fmt.Sprintf("  SKIP: stopped at a bot check: %s\n", currentURL),
			skip:   true,
		}
	}

	if !isHTTPURL(currentURL) {
		return bookmarkResult{
			report: fmt.Sprintf("  SKIP: final URL is not HTTP(S): %s\n", currentURL),
			skip:   true,
		}
	}

	if currentURL == oldURL {
		if navErr != nil {
			return bookmarkResult{report: fmt.Sprintf("  WARNING: navigation error: %v\n", navErr)}
		}
		return bookmarkResult{report: "  Unchanged\n"}
	}

	return bookmarkResult{
		newURL: currentURL,
		report: fmt.Sprintf("  OLD: %s\n  NEW: %s\n", oldURL, currentURL),
	}
}

// isLoginRedirect prevents login pages from being saved as destination URLs.
func isLoginRedirect(rawURL string) bool {
	u, err := url.Parse(rawURL)
	if err != nil {
		return false
	}

	host := strings.ToLower(u.Hostname())
	for _, prefix := range []string{"login.", "signin.", "auth.", "sso.", "accounts."} {
		if strings.HasPrefix(host, prefix) {
			return true
		}
	}

	for _, segment := range strings.Split(strings.ToLower(u.Path), "/") {
		switch segment {
		case "login", "log-in", "signin", "sign-in", "sign_in",
			"auth", "authorize", "oauth", "oauth2", "sso", "session", "sessions":
			return true
		}
	}

	return false
}

// isChallengePage catches bot checks that headless Edge cannot pass.
func isChallengePage(rawURL string) bool {
	u, err := url.Parse(rawURL)
	if err != nil {
		return false
	}

	return strings.Contains(u.Path, "/cdn-cgi/") ||
		strings.Contains(u.RawQuery, "__cf_chl_")
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
