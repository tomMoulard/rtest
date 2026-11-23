package cli

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"
)

func TestParseArgs(t *testing.T) {
	tests := []struct {
		name    string
		args    []string
		want    options
		wantErr string
	}{
		{
			name: "command flags stay with the command",
			args: []string{"go", "test", "-run", "TestX", "./..."},
			want: options{host: "rtest", command: []string{"go", "test", "-run", "TestX", "./..."}},
		},
		{
			name: "options before the command",
			args: []string{"-H", "box", "-q", "-k", "-t", "30", "-e", "A=1", "--env=B=x y", "make", "test"},
			want: options{
				host: "box", quiet: true, keep: true, timeout: 30,
				envs: []string{"A=1", "B=x y"}, command: []string{"make", "test"},
			},
		},
		{
			name: "double dash ends the options",
			args: []string{"--host=box", "--", "-q"},
			want: options{host: "box", command: []string{"-q"}},
		},
		{
			name: "info needs no command",
			args: []string{"--info"},
			want: options{host: "rtest", info: true},
		},
		{name: "missing command", args: []string{"-q"}, wantErr: errMissingCommand.Error()},
		{name: "missing value", args: []string{"-H"}, wantErr: "missing value for -H"},
		{name: "unknown option", args: []string{"--nope", "x"}, wantErr: `unknown option "--nope"`},
		{name: "bad timeout", args: []string{"-t", "soon", "x"}, wantErr: `invalid --timeout "soon"`},
		{name: "bad env", args: []string{"-e", "1A=x", "x"}, wantErr: `invalid --env "1A=x"`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := parseArgs(tt.args, "")
			if tt.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), tt.wantErr) {
					t.Fatalf("err = %v, want %q", err, tt.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(got, tt.want) {
				t.Errorf("got %+v\nwant %+v", got, tt.want)
			}
		})
	}
}

func TestParseArgsHostFromEnvironment(t *testing.T) {
	got, err := parseArgs([]string{"true"}, "from-env")
	if err != nil || got.host != "from-env" {
		t.Fatalf("host = %q, err = %v", got.host, err)
	}
}

func bash(t *testing.T, dir, script string) string {
	t.Helper()
	cmd := exec.Command("bash", "-c", script)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("bash: %v\n%s", err, out)
	}
	return string(out)
}

func TestShellQuoteRoundTrip(t *testing.T) {
	for _, s := range []string{"", "plain", "two words", "it's", `a"b`, "$HOME", "`id`", "a\nb", "*?[x]", "-n", "é ü"} {
		got := bash(t, "", "printf %s "+shellQuote(s))
		if got != s {
			t.Errorf("shellQuote(%q) gives %q", s, got)
		}
	}
}

func TestBuildScript(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "sub dir"), 0o755); err != nil {
		t.Fatal(err)
	}

	t.Run("arguments are one command", func(t *testing.T) {
		script := buildScript([]string{"GREETING=hello world"}, "sub dir",
			[]string{"printf", "%s|", "$GREETING", "it's", "two words"})
		if got := bash(t, dir, script); got != "$GREETING|it's|two words|" {
			t.Errorf("got %q", got)
		}
	})

	t.Run("one argument is a shell script", func(t *testing.T) {
		script := buildScript([]string{"GREETING=hello world"}, "sub dir",
			[]string{`printf '%s|%s' "$GREETING" "$(basename "$PWD")"`})
		if got := bash(t, dir, script); got != "hello world|sub dir" {
			t.Errorf("got %q", got)
		}
	})

	t.Run("a missing directory exits 125", func(t *testing.T) {
		cmd := exec.Command("bash", "-c", buildScript(nil, "missing", []string{"true"}))
		cmd.Dir = dir
		var exitErr *exec.ExitError
		if err := cmd.Run(); !errors.As(err, &exitErr) || exitErr.ExitCode() != 125 {
			t.Errorf("err = %v, want exit status 125", err)
		}
	})
}

func TestSanitize(t *testing.T) {
	for in, want := range map[string]string{
		"my-repo":               "my-repo",
		"my repo (copy)":        "my_repo__copy_",
		".hidden":               "_hidden",
		strings.Repeat("a", 50): strings.Repeat("a", 40),
		"":                      "_",
	} {
		if got := sanitize(in); got != want {
			t.Errorf("sanitize(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestMirrorKey(t *testing.T) {
	a := mirrorKey("/src/proj", "laptop")
	if a != mirrorKey("/src/proj", "laptop") {
		t.Error("the key is not stable")
	}
	if a == mirrorKey("/src/other/proj", "laptop") || a == mirrorKey("/src/proj", "desktop") {
		t.Error("two checkouts share a key")
	}
	if !strings.HasPrefix(a, "proj-") {
		t.Errorf("key %q does not start with the directory name", a)
	}
}

func TestEscapePattern(t *testing.T) {
	if got := escapePattern(`a[1]*?\b`); got != `a\[1\]\*\?\\b` {
		t.Errorf("got %q", got)
	}
}

func gitRepo(t *testing.T) string {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is not installed")
	}
	dir := t.TempDir()
	bash(t, dir, `
		git init -q
		mkdir -p sub build node_modules/x
		printf 'build/\nnode_modules/\n*.log\n!keep.log\n' > .gitignore
		touch sub/a.go build/out node_modules/x/y debug.log keep.log 'odd[1].log'
		git remote add origin https://example.com/proj.git`)
	return dir
}

func TestExcludePatterns(t *testing.T) {
	dir := gitRepo(t)
	p, err := findProject(dir, dir)
	if err != nil {
		t.Fatal(err)
	}
	got, err := excludePatterns(p)
	if err != nil {
		t.Fatal(err)
	}
	slices.Sort(got)
	want := []string{".git", "/build/", "/debug.log", "/node_modules/", `/odd\[1\].log`}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %q\nwant %q", got, want)
	}
}

func TestFindProject(t *testing.T) {
	dir := gitRepo(t)
	root, _ := filepath.EvalSymlinks(dir)

	p, err := findProject("", filepath.Join(dir, "sub"))
	if err != nil {
		t.Fatal(err)
	}
	if p.root != root || p.rel != "sub" || !p.git {
		t.Errorf("got %+v, want root %s, rel sub, git", p, root)
	}

	plain := t.TempDir()
	p, err = findProject(plain, plain)
	if err != nil {
		t.Fatal(err)
	}
	if p.git || p.rel != "" {
		t.Errorf("got %+v, want no git and no rel", p)
	}

	if _, err := findProject(filepath.Join(plain, "missing"), plain); err == nil {
		t.Error("a missing directory gives no error")
	}
}

func TestSeedName(t *testing.T) {
	dir := gitRepo(t)
	if got := seedName(dir); !strings.HasPrefix(got, "repo-") {
		t.Errorf("seedName = %q", got)
	}
	if got := seedName(t.TempDir()); got != "-" {
		t.Errorf("seedName without git = %q, want -", got)
	}
}

func TestSSHCommand(t *testing.T) {
	if got := sshCommand("ssh -F cfg", true); !reflect.DeepEqual(got, []string{"ssh", "-F", "cfg"}) {
		t.Errorf("no mux: got %q", got)
	}

	// A short cache directory gets a control socket. rtest creates the
	// directory, because a fresh CI runner has no ~/.ssh or cache directory.
	short, err := os.MkdirTemp("/tmp", "rt")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(short) })
	t.Setenv("HOME", short)
	t.Setenv("XDG_CACHE_HOME", filepath.Join(short, ".cache"))
	got := sshCommand("", false)
	if !slices.Contains(got, "ControlMaster=auto") {
		t.Fatalf("mux: got %q", got)
	}
	cacheDir, _ := os.UserCacheDir()
	if fi, err := os.Stat(filepath.Join(cacheDir, "rtest")); err != nil || !fi.IsDir() {
		t.Errorf("control directory was not created: %v", err)
	}

	// A path over the socket length limit disables sharing.
	long := filepath.Join(short, strings.Repeat("d", 80))
	t.Setenv("HOME", long)
	t.Setenv("XDG_CACHE_HOME", filepath.Join(long, ".cache"))
	if got := sshCommand("", false); slices.Contains(got, "ControlMaster=auto") {
		t.Errorf("long path: got %q", got)
	}
}

func TestEncodeScript(t *testing.T) {
	enc := encodeScript("echo 'a b'\n")
	if strings.ContainsAny(enc, " '\n") {
		t.Errorf("encoded script %q is not one plain word", enc)
	}
}
