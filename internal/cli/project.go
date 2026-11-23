package cli

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// project describes the directory that rtest sends.
type project struct {
	root string // absolute path, symbolic links resolved
	rel  string // working directory relative to root, "" for the root
	git  bool   // root is inside a git work tree
}

// findProject resolves the project root and the relative working directory.
// Without dir, the root is the git top level, else the working directory.
func findProject(dir, workdir string) (project, error) {
	here, err := filepath.EvalSymlinks(workdir)
	if err != nil {
		return project{}, err
	}
	if dir == "" {
		dir = here
		if top, err := gitOutput(here, "rev-parse", "--show-toplevel"); err == nil {
			dir = strings.TrimSpace(top)
		}
	}
	abs, err := filepath.Abs(dir)
	if err != nil {
		return project{}, err
	}
	root, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return project{}, fmt.Errorf("no such directory: %s", dir)
	}
	if fi, err := os.Stat(root); err != nil || !fi.IsDir() {
		return project{}, fmt.Errorf("not a directory: %s", dir)
	}

	p := project{root: root}
	if rel, err := filepath.Rel(root, here); err == nil && rel != "." && !strings.HasPrefix(rel, "..") {
		p.rel = filepath.ToSlash(rel)
	}
	out, err := gitOutput(root, "rev-parse", "--is-inside-work-tree")
	p.git = err == nil && strings.TrimSpace(out) == "true"
	return p, nil
}

// mirrorKey names the server mirror of this checkout: one mirror per machine
// and per directory, so that parallel runs of one checkout share it.
func mirrorKey(root, hostname string) string {
	name := sanitize(filepath.Base(root))
	return name + "-" + shortHash(hostname+":"+root)
}

// seedName names the repository, from the origin remote URL. A new mirror
// starts as a copy of the latest mirror of the same repository. "-" means
// that there is no seed.
func seedName(root string) string {
	origin, err := gitOutput(root, "config", "--get", "remote.origin.url")
	origin = strings.TrimSpace(origin)
	if err != nil || origin == "" {
		return "-"
	}
	return "repo-" + shortHash(origin)
}

func shortHash(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])[:12]
}

// sanitize keeps a name safe for a path component on the server.
func sanitize(name string) string {
	var b strings.Builder
	for _, r := range name {
		switch {
		case r >= 'A' && r <= 'Z', r >= 'a' && r <= 'z', r >= '0' && r <= '9', r == '.', r == '_', r == '-':
			b.WriteRune(r)
		default:
			b.WriteByte('_')
		}
	}
	s := b.String()
	if len(s) > 40 {
		s = s[:40]
	}
	if s == "" || s[0] == '.' {
		s = "_" + strings.TrimPrefix(s, ".")
	}
	return s
}

// excludePatterns returns the rsync exclude patterns: .git, and in a git work
// tree every path that git ignores. git lists them itself, so that every
// gitignore rule applies.
func excludePatterns(p project) ([]string, error) {
	patterns := []string{".git"}
	if !p.git {
		return patterns, nil
	}
	out, err := gitOutput(p.root, "ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory")
	if err != nil {
		return nil, fmt.Errorf("git ls-files: %w", err)
	}
	for _, path := range strings.Split(out, "\x00") {
		if path != "" {
			patterns = append(patterns, "/"+escapePattern(path))
		}
	}
	return patterns, nil
}

// escapePattern makes rsync match the path literally.
func escapePattern(path string) string {
	var b strings.Builder
	for _, r := range path {
		switch r {
		case '[', ']', '*', '?', '\\':
			b.WriteByte('\\')
		}
		b.WriteRune(r)
	}
	return b.String()
}

func gitOutput(dir string, args ...string) (string, error) {
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	var out bytes.Buffer
	cmd.Stdout = &out
	err := cmd.Run()
	return out.String(), err
}
