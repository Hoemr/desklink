package main

import (
	"bytes"
	"html"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDeviceRoutes(t *testing.T) {
	const address = "100.64.0.2:21118"
	tests := []struct {
		name, fields, wantID, wantAddr, wantTarget, wantError string
	}{
		{name: "legacy IP", fields: `"id":"100.64.0.2:21118","ssh":"mini","ssh_local_port":22118`, wantAddr: address, wantTarget: address},
		{name: "device ID and private address", fields: `"id":"123456789","address":"100.64.0.2:21118","ssh":"mini","ssh_local_port":22118`, wantID: "123456789", wantAddr: address, wantTarget: "123456789"},
		{name: "address only", fields: `"address":"100.64.0.2:21118"`, wantAddr: address, wantTarget: address},
		{name: "duplicate addresses", fields: `"id":"100.64.0.2:21118","address":"100.64.0.3:21118"`, wantError: "use only address"},
		{name: "invalid address", fields: `"address":"100.64.0.2:0"`, wantError: "must be a RustDesk IPv4:port"},
		{name: "tunnel without address", fields: `"id":"123456789","ssh":"mini","ssh_local_port":22118`, wantError: "requires an SSH alias and an address"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "desklink.json")
			data := `{"devices":[{"name":"mini",` + tc.fields + `}]}`
			if err := os.WriteFile(path, []byte(data), 0600); err != nil {
				t.Fatal(err)
			}
			cfg, err := loadConfig(path)
			if tc.wantError != "" {
				if err == nil || !strings.Contains(err.Error(), tc.wantError) {
					t.Fatalf("loadConfig error = %v, want %q", err, tc.wantError)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			dev := cfg.Devices[0]
			if dev.ID != tc.wantID || dev.Address != tc.wantAddr || dev.Target() != tc.wantTarget {
				t.Fatalf("unexpected routes: id=%q address=%q target=%q", dev.ID, dev.Address, dev.Target())
			}
		})
	}
}

func TestTunnelUsesItsOwnSSHAlias(t *testing.T) {
	dev := device{SSH: "mini", SSHTunnel: "mini-tunnel"}
	if got := dev.tunnelAlias(); got != "mini-tunnel" {
		t.Fatalf("tunnel alias = %q", got)
	}
	dev.SSHTunnel = ""
	if got := dev.tunnelAlias(); got != "mini" {
		t.Fatalf("legacy tunnel alias = %q", got)
	}
	path := filepath.Join(t.TempDir(), "desklink.json")
	data := `{"devices":[{"name":"mini","address":"100.64.0.2:21118","ssh_tunnel":"-not-an-alias","ssh_local_port":22118}]}`
	if err := os.WriteFile(path, []byte(data), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadConfig(path); err == nil || !strings.Contains(err.Error(), "invalid ssh_tunnel") {
		t.Fatalf("invalid tunnel alias error = %v", err)
	}
}

func TestCopyUsesIndependentSSHAndLiteralLocalPath(t *testing.T) {
	local := filepath.Join(t.TempDir(), "large file.bin")
	const remote = "/tmp/large file.bin"
	for _, test := range []struct{ command, source, destination, wantSource, wantDestination string }{
		{"send", local, remote, local, "mini-bulk:" + remote},
		{"get", remote, local, "mini-bulk:" + remote, local},
	} {
		args, err := copyArguments(test.command, "mini-bulk", test.source, test.destination)
		if err != nil {
			t.Fatal(err)
		}
		if args[0] != "-s" || !strings.Contains(strings.Join(args, " "), "Compression=no -o ControlMaster=no -o ControlPath=none --") || args[len(args)-2] != test.wantSource || args[len(args)-1] != test.wantDestination {
			t.Fatalf("%s args = %q", test.command, args)
		}
	}
	if _, err := copyArguments("send", "", local, remote); err == nil {
		t.Fatal("accepted a missing SSH alias")
	}
	if _, err := copyArguments("get", "mini-bulk", remote, " "); err == nil {
		t.Fatal("accepted a missing destination")
	}
}

func TestPanelShowsBothRoutesAndImportProfile(t *testing.T) {
	cfg := config{
		IDServer: " relay.example.com ", ServerKey: " public-key ",
		Devices: []device{{Name: "mini", ID: "123456789", Address: "100.64.0.2:21118", SSHUser: "user"}},
	}
	var buf bytes.Buffer
	if err := renderPanel(&buf, cfg); err != nil {
		t.Fatal(err)
	}
	page := html.UnescapeString(buf.String())
	for _, want := range []string{
		`class="primary" href="rustdesk://connection/new/123456789@relay.example.com?key=public-key"`,
		`class="ip-link" href="rustdesk://connection/new/100.64.0.2:21118"`,
		`user@100.64.0.2`,
		`{"host":"relay.example.com","key":"public-key"}`,
	} {
		if !strings.Contains(page, want) {
			t.Errorf("missing %q in panel", want)
		}
	}
}

func TestRustDeskLinksPinTheServerForIDs(t *testing.T) {
	profile := serverProfile{Host: "relay.example.com:21116", Key: "ab+C/de="}
	link := rustDeskURL("connection/new/", "123456789", profile)
	u, err := url.Parse(link)
	if err != nil || u.Path != "/new/123456789@relay.example.com:21116" || u.Query().Get("key") != profile.Key {
		t.Fatalf("invalid scoped link %q: %v", link, err)
	}
	for _, target := range []string{"127.0.0.1:22118", "100.64.0.2:21118"} {
		if got := rustDeskURL("connection/new/", target, profile); got != "rustdesk://connection/new/"+target {
			t.Errorf("direct link changed: %s", got)
		}
	}
	profile.Host = "relay.example.com'@other"
	if got := rustDeskURL("terminal/", "123456789", profile); got != "rustdesk://terminal/123456789" {
		t.Errorf("unsafe server appeared in link: %s", got)
	}
}
