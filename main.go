package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
)

const usage = `Usage: desklink [-config FILE] [-via-ssh] COMMAND

  list                       List devices
  server                     Show the ID server and its public key
  profile                    Print the RustDesk clipboard import profile
  panel                      Serve the device panel at 127.0.0.1:22180
  desktop DEVICE             Open a RustDesk desktop session
  terminal DEVICE            Open a RustDesk terminal session
  files DEVICE               Open RustDesk file transfer
  tunnel DEVICE              Forward the device's RustDesk port over SSH
  ssh DEVICE [COMMAND]       Open SSH or run a remote command
  term DEVICE [SESSION]      Attach to or create a named tmux session
  sessions DEVICE            List named tmux sessions

For desktop, terminal and files, -via-ssh uses a running local tunnel.
Default config: desklink.json beside the executable.`

var (
	namePattern   = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$`)
	sshPattern    = regexp.MustCompile(`^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,63}$`)
	rustDeskPaths = map[string]string{
		"desktop":  "connection/new/",
		"terminal": "terminal/",
		"files":    "file-transfer/",
	}
)

type device struct {
	Name         string `json:"name"`
	ID           string `json:"id"`
	SSH          string `json:"ssh"`
	SSHUser      string `json:"ssh_user"`
	SSHLocalPort uint16 `json:"ssh_local_port"`
}

type config struct {
	IDServer  string   `json:"id_server"`
	ServerKey string   `json:"server_key"`
	Devices   []device `json:"devices"`
}

func loadConfig(path string) (config, error) {
	var cfg config
	file, err := os.Open(path)
	if err != nil {
		return cfg, err
	}
	defer file.Close()
	decoder := json.NewDecoder(file)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&cfg); err != nil {
		return cfg, fmt.Errorf("%s: %w", path, err)
	}
	if decoder.Decode(new(json.RawMessage)) != io.EOF {
		return cfg, fmt.Errorf("%s: expected one JSON object", path)
	}
	seen := make(map[string]bool)
	localPorts := make(map[uint16]string)
	for _, dev := range cfg.Devices {
		if !namePattern.MatchString(dev.Name) || seen[dev.Name] {
			return cfg, fmt.Errorf("invalid or duplicate device name %q", dev.Name)
		}
		seen[dev.Name] = true
		addr, addrErr := netip.ParseAddrPort(dev.ID)
		directTarget := addrErr == nil && addr.Addr().Is4() && addr.Port() != 0
		if dev.ID != "" && !namePattern.MatchString(dev.ID) && !directTarget {
			return cfg, fmt.Errorf("invalid RustDesk ID or IPv4:port for %q", dev.Name)
		}
		if dev.SSH != "" && !sshPattern.MatchString(dev.SSH) {
			return cfg, fmt.Errorf("invalid SSH alias for %q", dev.Name)
		}
		if dev.SSHUser != "" && (!sshPattern.MatchString(dev.SSHUser) || !directTarget) {
			return cfg, fmt.Errorf("ssh_user for %q requires a valid username and a RustDesk IPv4:port", dev.Name)
		}
		if dev.SSHLocalPort != 0 {
			if !directTarget || dev.SSH == "" {
				return cfg, fmt.Errorf("SSH tunnel for %q requires an SSH alias and a RustDesk IPv4:port", dev.Name)
			}
			if other, used := localPorts[dev.SSHLocalPort]; used {
				return cfg, fmt.Errorf("ssh_local_port %d is shared by %q and %q", dev.SSHLocalPort, other, dev.Name)
			}
			localPorts[dev.SSHLocalPort] = dev.Name
		}
	}
	return cfg, nil
}

func launch(uri string) error {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("open", uri)
	case "windows":
		cmd = exec.Command("powershell.exe", "-NoProfile", "-NonInteractive", "-Command", "Start-Process -FilePath '"+uri+"' -ErrorAction Stop")
	default:
		return fmt.Errorf("RustDesk launching is unavailable on %s", runtime.GOOS)
	}
	return interactive(cmd)
}

func rustDeskURL(path, target string) string {
	return "rustdesk://" + path + target
}

func interactive(cmd *exec.Cmd) error {
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	return cmd.Run()
}

func run(args []string) error {
	flags := flag.NewFlagSet("desklink", flag.ContinueOnError)
	path := flags.String("config", "", "read this device configuration")
	viaSSH := flags.Bool("via-ssh", false, "connect via the device's local SSH tunnel")
	flags.Usage = func() { fmt.Fprintln(flags.Output(), usage) }
	if err := flags.Parse(args); err != nil {
		return err
	}
	args = flags.Args()
	if len(args) == 0 || args[0] == "help" {
		fmt.Println(usage)
		return nil
	}
	command := args[0]
	if _, ok := rustDeskPaths[command]; *viaSSH && !ok {
		return errors.New("-via-ssh requires desktop, terminal or files")
	}
	switch command {
	case "list", "server", "profile", "panel":
		if len(args) != 1 {
			return fmt.Errorf("usage: desklink %s", command)
		}
	case "desktop", "terminal", "files", "sessions", "tunnel":
		if len(args) != 2 {
			return fmt.Errorf("usage: desklink %s DEVICE", command)
		}
	case "term":
		if len(args) < 2 || len(args) > 3 {
			return errors.New("usage: desklink term DEVICE [SESSION]")
		}
	case "ssh":
		if len(args) < 2 {
			return errors.New("usage: desklink ssh DEVICE [COMMAND]")
		}
	default:
		return fmt.Errorf("unknown command %q (see desklink help)", command)
	}
	if *path == "" {
		exe, err := os.Executable()
		if err != nil {
			return err
		}
		*path = filepath.Join(filepath.Dir(exe), "desklink.json")
	}
	cfg, err := loadConfig(*path)
	if err != nil {
		return err
	}
	switch command {
	case "panel":
		return servePanel(cfg.Devices)
	case "list":
		for _, dev := range cfg.Devices {
			fmt.Printf("%s\tRustDesk=%s\tSSH=%s\n", dev.Name, dev.ID, dev.SSH)
		}
		return nil
	case "server", "profile":
		host, key := strings.TrimSpace(cfg.IDServer), strings.TrimSpace(cfg.ServerKey)
		if host == "" || key == "" {
			return errors.New("set id_server and server_key in desklink.json")
		}
		if command == "profile" {
			return json.NewEncoder(os.Stdout).Encode(map[string]string{"host": host, "key": key})
		}
		fmt.Printf("ID server: %s\nKey: %s\n", host, key)
		return nil
	}
	for _, dev := range cfg.Devices {
		if dev.Name == args[1] {
			return connect(command, dev, args[2:], *viaSSH)
		}
	}
	return fmt.Errorf("unknown device %q (see desklink list)", args[1])
}

func connect(command string, dev device, args []string, viaSSH bool) error {
	target := dev.ID
	if viaSSH || command == "tunnel" {
		if dev.SSHLocalPort == 0 {
			return fmt.Errorf("set ssh_local_port for %q", dev.Name)
		}
		local := fmt.Sprintf("127.0.0.1:%d", dev.SSHLocalPort)
		if command == "tunnel" {
			return interactive(exec.Command("ssh", "-NT", "-S", "none", "-o", "ExitOnForwardFailure=yes", "-L", local+":"+target, dev.SSH))
		}
		conn, err := net.Dial("tcp", local)
		if err != nil {
			return fmt.Errorf("start desklink tunnel %s first: %w", dev.Name, err)
		}
		conn.Close()
		target = local
	}
	if path, ok := rustDeskPaths[command]; ok {
		if target == "" {
			return fmt.Errorf("no RustDesk ID configured for %q", dev.Name)
		}
		return launch(rustDeskURL(path, target))
	}
	if dev.SSH == "" {
		return fmt.Errorf("no SSH alias configured for %q", dev.Name)
	}
	switch command {
	case "term":
		name := "main"
		if len(args) == 1 {
			name = args[0]
		}
		if !namePattern.MatchString(name) {
			return fmt.Errorf("invalid session name %q", name)
		}
		return interactive(exec.Command("ssh", "-tt", dev.SSH, "tmux", "-L", "desklink", "new-session", "-A", "-s", name))
	case "sessions":
		return interactive(exec.Command("ssh", dev.SSH, "tmux", "-L", "desklink", "list-sessions"))
	default:
		return interactive(exec.Command("ssh", append([]string{dev.SSH}, args...)...))
	}
}

func main() {
	err := run(os.Args[1:])
	if err == nil || errors.Is(err, flag.ErrHelp) {
		return
	}
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		if code := exit.ExitCode(); code > 0 {
			os.Exit(code)
		}
	}
	fmt.Fprintln(os.Stderr, "desklink:", err)
	os.Exit(1)
}
