package main

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"fmt"
	"html/template"
	"io"
	"net"
	"net/http"
	"net/netip"
	"os"
	"time"
)

//go:embed panel.html
var panelHTML string

var devicePanel = template.Must(template.New("panel").Funcs(template.FuncMap{
	"remote": func(command, target string, profile serverProfile) template.URL {
		return template.URL(rustDeskURL(rustDeskPaths[command], target, profile))
	},
	"sshAddress": func(dev device) string {
		address, _ := netip.ParseAddrPort(dev.Address)
		return dev.SSHUser + "@" + address.Addr().String()
	},
}).Parse(panelHTML))

func renderPanel(w io.Writer, cfg config) error {
	view := struct {
		Devices []device
		Profile string
		Server  serverProfile
	}{Devices: cfg.Devices, Server: cfg.profile()}
	if view.Server.Host != "" && view.Server.Key != "" {
		data, err := json.Marshal(view.Server)
		if err != nil {
			return err
		}
		view.Profile = string(data)
	}
	return devicePanel.Execute(w, view)
}

func servePanel(cfg config) error {
	var document bytes.Buffer
	if err := renderPanel(&document, cfg); err != nil {
		return err
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'")
		w.Write(document.Bytes())
	})

	listener, err := net.Listen("tcp4", "127.0.0.1:22180")
	if err != nil {
		return err
	}
	fmt.Fprintln(os.Stderr, "Desklink panel: http://"+listener.Addr().String())
	server := &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	return server.Serve(listener)
}
