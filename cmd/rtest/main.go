// Command rtest runs a command on a remote rtest server, on a copy of the
// current project, and exits with the exit status of the command.
package main

import (
	"os"
	"runtime/debug"

	"github.com/tomMoulard/rtest/internal/cli"
)

// version is set at release time with -ldflags "-X main.version=v1.2.3".
var version = ""

func main() {
	os.Exit(cli.Main(resolveVersion(), os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
}

// resolveVersion also covers `go install ...@v1.2.3`, which sets the module
// version but not the linker flag.
func resolveVersion() string {
	if version != "" {
		return version
	}
	if info, ok := debug.ReadBuildInfo(); ok && info.Main.Version != "" {
		return info.Main.Version
	}
	return "dev"
}
