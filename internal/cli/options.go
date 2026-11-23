// Package cli implements the rtest client: it sends a project to an rtest
// server, runs one command there, and returns the exit status of the command.
package cli

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
)

// Exit statuses of rtest itself. The other statuses come from the command.
const (
	exitUsage  = 125 // rtest did not prepare the run.
	exitSSH    = 255 // SSH failed.
	defaultSSH = "rtest"
)

const usage = `Usage: rtest [options] [--] COMMAND [ARGS...]
       rtest --info

Copies the project to the rtest server, runs COMMAND there from the same
relative directory, streams the output, and exits with the exit status of
COMMAND. The remote copy is deleted when COMMAND ends.

A single COMMAND argument is a shell script: rtest 'go vet ./... && go test ./...'
Several arguments are one command with its arguments: rtest go test -run TestX ./pkg

Options:
  -H, --host HOST      SSH destination (default: $RTEST_HOST, else "rtest")
  -C, --dir DIR        project directory to copy (default: the git top level,
                       else the current directory)
  -e, --env NAME=VALUE set a variable for COMMAND (repeatable)
  -t, --timeout SECS   stop COMMAND after SECS seconds (exit status 124)
  -k, --keep           keep the remote copy, for debugging
  -q, --quiet          do not print the rtest status lines
      --info           print the server toolchain versions and exit
  -h, --help           print this help
  -V, --version        print the version

Environment:
  RTEST_HOST     default SSH destination
  RTEST_SSH      SSH command and options, split on spaces (default: "ssh")
  RTEST_NO_MUX   set to 1 to disable SSH connection sharing

Exit status: the exit status of COMMAND, 124 on timeout, 125 when rtest
cannot prepare the run, 255 when SSH fails.
`

// options holds the parsed command line.
type options struct {
	host    string
	dir     string
	envs    []string
	timeout int
	keep    bool
	quiet   bool
	info    bool
	help    bool
	version bool
	command []string
}

var errMissingCommand = errors.New("missing COMMAND, see rtest --help")

// parseArgs reads the options up to the first argument that is not an option,
// or up to "--". The remaining arguments are the command.
func parseArgs(args []string, defaultHost string) (options, error) {
	opts := options{host: defaultHost}
	if opts.host == "" {
		opts.host = defaultSSH
	}

	for len(args) > 0 {
		arg := args[0]
		if arg == "--" {
			args = args[1:]
			break
		}
		if !strings.HasPrefix(arg, "-") || arg == "-" {
			break
		}
		args = args[1:]

		name, value, hasValue := strings.Cut(arg, "=")
		if !strings.HasPrefix(name, "--") {
			hasValue = false
			name, value = arg, ""
		}
		takeValue := func() (string, error) {
			if hasValue {
				return value, nil
			}
			if len(args) == 0 {
				return "", fmt.Errorf("missing value for %s", name)
			}
			v := args[0]
			args = args[1:]
			return v, nil
		}

		var err error
		switch name {
		case "-H", "--host":
			opts.host, err = takeValue()
		case "-C", "--dir":
			opts.dir, err = takeValue()
		case "-e", "--env":
			var kv string
			if kv, err = takeValue(); err == nil {
				if !validEnv(kv) {
					return opts, fmt.Errorf("invalid --env %q, want NAME=VALUE", kv)
				}
				opts.envs = append(opts.envs, kv)
			}
		case "-t", "--timeout":
			var v string
			if v, err = takeValue(); err == nil {
				opts.timeout, err = strconv.Atoi(v)
				if err != nil || opts.timeout < 0 {
					return opts, fmt.Errorf("invalid --timeout %q", v)
				}
			}
		case "-k", "--keep":
			opts.keep = true
		case "-q", "--quiet":
			opts.quiet = true
		case "--info":
			opts.info = true
		case "-h", "--help":
			opts.help = true
		case "-V", "--version":
			opts.version = true
		default:
			return opts, fmt.Errorf("unknown option %q, see rtest --help", arg)
		}
		if err != nil {
			return opts, err
		}
	}

	if len(args) > 0 {
		opts.command = args
	}
	if len(opts.command) == 0 && !opts.info && !opts.help && !opts.version {
		return opts, errMissingCommand
	}
	return opts, nil
}

// validEnv accepts NAME=VALUE where NAME is a shell variable name.
func validEnv(kv string) bool {
	name, _, ok := strings.Cut(kv, "=")
	if !ok || name == "" {
		return false
	}
	for i, r := range name {
		switch {
		case r == '_', r >= 'A' && r <= 'Z', r >= 'a' && r <= 'z':
		case r >= '0' && r <= '9' && i > 0:
		default:
			return false
		}
	}
	return true
}
