package cli

import (
	"encoding/base64"
	"strings"
)

// buildScript returns the bash script that the server runs in the run
// directory: the variables, the directory change, then the command. A single
// command argument is a shell script. Several arguments are one command.
func buildScript(envs []string, rel string, command []string) string {
	var b strings.Builder
	for _, kv := range envs {
		name, value, _ := strings.Cut(kv, "=")
		b.WriteString("export " + name + "=" + shellQuote(value) + "\n")
	}
	if rel != "" {
		b.WriteString("cd " + shellQuote(rel) + " || exit 125\n")
	}
	if len(command) == 1 {
		b.WriteString(command[0])
	} else {
		quoted := make([]string, len(command))
		for i, arg := range command {
			quoted[i] = shellQuote(arg)
		}
		b.WriteString(strings.Join(quoted, " "))
	}
	return b.String()
}

// encodeScript makes the script safe to pass as one SSH argument.
func encodeScript(script string) string {
	return base64.StdEncoding.EncodeToString([]byte(script))
}

// shellQuote quotes s for a POSIX shell.
func shellQuote(s string) string {
	if s == "" {
		return "''"
	}
	safe := true
	for _, r := range s {
		if !(r >= 'A' && r <= 'Z' || r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || strings.ContainsRune("@%+=:,./_-", r)) {
			safe = false
			break
		}
	}
	if safe {
		return s
	}
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}
