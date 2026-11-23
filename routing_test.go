package main

import (
	"bytes"
	"html"
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
		`class="primary" href="rustdesk://connection/new/123456789"`,
		`class="ip-link" href="rustdesk://connection/new/100.64.0.2:21118"`,
		`user@100.64.0.2`,
		`{"host":"relay.example.com","key":"public-key"}`,
	} {
		if !strings.Contains(page, want) {
			t.Errorf("missing %q in panel", want)
		}
	}
}
