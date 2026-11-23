package cli

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"golang.org/x/term"
)

// maxControlPath keeps the SSH control socket path under the 104-byte limit
// of macOS. %C expands to 40 characters.
const maxControlPath = 100

// Main runs rtest and returns the exit status.
func Main(version string, args []string, stdin *os.File, stdout, stderr io.Writer) int {
	opts, err := parseArgs(args, os.Getenv("RTEST_HOST"))
	switch {
	case opts.help:
		fmt.Fprint(stdout, usage)
		return 0
	case opts.version:
		fmt.Fprintln(stdout, "rtest", version)
		return 0
	case errors.Is(err, errMissingCommand):
		fmt.Fprint(stderr, usage)
		return exitUsage
	case err != nil:
		fmt.Fprintln(stderr, "rtest:", err)
		return exitUsage
	}

	r := &runner{opts: opts, stdin: stdin, stdout: stdout, stderr: stderr}
	r.ssh = sshCommand(os.Getenv("RTEST_SSH"), os.Getenv("RTEST_NO_MUX") == "1")
	if opts.info {
		return r.runSSH(false, opts.host, "rtest-info")
	}
	return r.run()
}

type runner struct {
	opts   options
	ssh    []string
	stdin  *os.File
	stdout io.Writer
	stderr io.Writer
}

func (r *runner) say(format string, args ...any) {
	if !r.opts.quiet {
		fmt.Fprintf(r.stderr, "rtest: "+format+"\n", args...)
	}
}

func (r *runner) fail(format string, args ...any) int {
	fmt.Fprintf(r.stderr, "rtest: "+format+"\n", args...)
	return exitUsage
}

func (r *runner) run() int {
	if _, err := exec.LookPath("rsync"); err != nil {
		return r.fail("rsync is not installed")
	}
	wd, err := os.Getwd()
	if err != nil {
		return r.fail("%v", err)
	}
	p, err := findProject(r.opts.dir, wd)
	if err != nil {
		return r.fail("%v", err)
	}

	hostname, _ := os.Hostname()
	hostname, _, _ = strings.Cut(hostname, ".")
	key := mirrorKey(p.root, hostname)
	seed := seedName(p.root)
	run := runID()

	// The exclude list is the only local file. It goes away at exit.
	patterns, err := excludePatterns(p)
	if err != nil {
		return r.fail("%v", err)
	}
	exclude, err := os.CreateTemp("", "rtest-exclude-*")
	if err != nil {
		return r.fail("%v", err)
	}
	defer os.Remove(exclude.Name())
	_, err = exclude.WriteString(strings.Join(patterns, "\n") + "\n")
	if cerr := exclude.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return r.fail("%v", err)
	}

	rsyncArgs := []string{
		"-rlptz", "--delete", "--delete-excluded",
		"--exclude-from=" + exclude.Name(),
	}
	if !p.git {
		rsyncArgs = append(rsyncArgs, "-f", ":- .gitignore")
	}
	if _, err := os.Stat(filepath.Join(p.root, ".rtestignore")); err == nil {
		rsyncArgs = append(rsyncArgs, "--exclude-from="+filepath.Join(p.root, ".rtestignore"))
	}
	rsyncArgs = append(rsyncArgs,
		"-e", strings.Join(r.ssh, " "),
		"--rsync-path=rtest-sync "+key+" "+run+" "+seed,
		p.root+"/",
		r.opts.host+":/work/sources/"+key+"/",
	)

	r.say("sync %s -> %s", p.root, r.opts.host)
	start := time.Now()
	sync := exec.Command("rsync", rsyncArgs...)
	sync.Stdout, sync.Stderr = r.stderr, r.stderr
	if err := sync.Run(); err != nil {
		return r.fail("sync failed (%v)", err)
	}
	r.say("synced in %s, run %s", time.Since(start).Round(100*time.Millisecond), run)

	remote := []string{"rtest-exec"}
	if r.opts.keep {
		remote = append(remote, "--keep")
	}
	if r.opts.timeout > 0 {
		remote = append(remote, "--timeout", strconv.Itoa(r.opts.timeout))
	}
	remote = append(remote, run, encodeScript(buildScript(r.opts.envs, p.rel, r.opts.command)))

	tty := term.IsTerminal(int(r.stdin.Fd())) && isTerminal(r.stdout)
	rc := r.runSSH(tty, r.opts.host, remote...)
	r.say("exit status %d", rc)
	return rc
}

// runSSH runs a remote command and returns its exit status.
//
// With a terminal, SSH allocates a remote terminal: colors work and Ctrl-C
// stops the remote command. Without one (CI, agents), stdin stays open for the
// duration of the run, and the server stops the command when stdin closes.
func (r *runner) runSSH(tty bool, host string, remote ...string) int {
	args := append([]string{}, r.ssh[1:]...)
	if tty {
		args = append(args, "-t")
	}
	args = append(args, host)
	args = append(args, remote...)

	cmd := exec.Command(r.ssh[0], args...)
	cmd.Stdout, cmd.Stderr = r.stdout, r.stderr
	var keepOpen *os.File
	if tty {
		cmd.Stdin = r.stdin
	} else {
		pr, pw, err := os.Pipe()
		if err != nil {
			return r.fail("%v", err)
		}
		defer pr.Close()
		keepOpen = pw
		cmd.Stdin = pr
	}

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer signal.Stop(signals)

	if err := cmd.Start(); err != nil {
		return r.fail("cannot start %s: %v", r.ssh[0], err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()

	var caught os.Signal
	for {
		select {
		case sig := <-signals:
			// With a terminal, Ctrl-C reaches the remote side through SSH.
			if tty && sig == os.Interrupt {
				continue
			}
			caught = sig
			if keepOpen != nil {
				keepOpen.Close()
				keepOpen = nil
			}
			_ = cmd.Process.Signal(syscall.SIGTERM)
		case err := <-done:
			if keepOpen != nil {
				keepOpen.Close()
			}
			if s, ok := caught.(syscall.Signal); ok {
				return 128 + int(s)
			}
			return exitStatus(err)
		}
	}
}

func exitStatus(err error) int {
	if err == nil {
		return 0
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) && exitErr.ExitCode() >= 0 {
		return exitErr.ExitCode()
	}
	return exitSSH
}

// sshCommand returns the SSH command line. Connection sharing lets the sync,
// the run and parallel runs reuse one connection.
func sshCommand(custom string, noMux bool) []string {
	cmd := strings.Fields(custom)
	if len(cmd) == 0 {
		cmd = []string{"ssh"}
	}
	if noMux {
		return cmd
	}
	dir, err := os.UserCacheDir()
	if err != nil {
		return cmd
	}
	dir = filepath.Join(dir, "rtest")
	if len(dir)+len("/")+40 > maxControlPath || strings.ContainsAny(dir, " \t") {
		return cmd
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return cmd
	}
	return append(cmd,
		"-o", "ControlMaster=auto",
		"-o", "ControlPath="+filepath.Join(dir, "%C"),
		"-o", "ControlPersist=10m",
	)
}

func runID() string {
	b := make([]byte, 3)
	_, _ = rand.Read(b)
	return fmt.Sprintf("%s-%d-%s", time.Now().Format("20060102-150405"), os.Getpid(), hex.EncodeToString(b))
}

func isTerminal(w io.Writer) bool {
	f, ok := w.(*os.File)
	return ok && term.IsTerminal(int(f.Fd()))
}
