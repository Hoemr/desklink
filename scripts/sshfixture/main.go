// The Windows CI job runs this loopback-only fixture using Windows OpenSSH.
package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"golang.org/x/crypto/ssh"
)

const marker = "desklink-tunnel-fixture"

func must[T any](v T, err error) T {
	check(err)
	return v
}

func check(err error) {
	if err != nil {
		panic(err)
	}
}

func listener() net.Listener {
	return must(net.Listen("tcp4", "127.0.0.1:0"))
}

func serve(listener net.Listener, config *ssh.ServerConfig, forward string, jumpCount *atomic.Int32) {
	for {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		go func() {
			defer conn.Close()
			client, channels, requests, err := ssh.NewServerConn(conn, config)
			if err != nil {
				return
			}
			defer client.Close()
			go ssh.DiscardRequests(requests)
			for channel := range channels {
				switch channel.ChannelType() {
				case "session":
					if jumpCount != nil {
						channel.Reject(ssh.Prohibited, "jump has no shell")
						continue
					}
					go session(channel)
				case "direct-tcpip":
					if jumpCount == nil && client.User() != "fixture-tunnel" {
						channel.Reject(ssh.Prohibited, "desktop forwarding requires the separate SSH alias")
						continue
					}
					go forwardChannel(channel, forward, jumpCount)
				default:
					channel.Reject(ssh.UnknownChannelType, "fixture channel unavailable")
				}
			}
		}()
	}
}

func session(request ssh.NewChannel) {
	channel, requests, err := request.Accept()
	if err != nil {
		return
	}
	defer channel.Close()
	for req := range requests {
		var payload struct{ Command string }
		if req.Type != "exec" || ssh.Unmarshal(req.Payload, &payload) != nil || payload.Command != "hostname" {
			req.Reply(false, nil)
			continue
		}
		req.Reply(true, nil)
		io.WriteString(channel, "desklink-test-host\n")
		channel.SendRequest("exit-status", false, ssh.Marshal(struct{ Status uint32 }{0}))
		return
	}
}

func forwardChannel(request ssh.NewChannel, forward string, jumpCount *atomic.Int32) {
	var payload struct {
		Host       string
		Port       uint32
		OriginHost string
		OriginPort uint32
	}
	if ssh.Unmarshal(request.ExtraData(), &payload) != nil || net.JoinHostPort(payload.Host, strconv.FormatUint(uint64(payload.Port), 10)) != forward {
		request.Reject(ssh.Prohibited, "fixture destination unavailable")
		return
	}
	upstream, err := net.DialTimeout("tcp4", forward, 3*time.Second)
	if err != nil {
		request.Reject(ssh.ConnectionFailed, "fixture destination did not answer")
		return
	}
	defer upstream.Close()
	channel, requests, err := request.Accept()
	if err != nil {
		return
	}
	defer channel.Close()
	go ssh.DiscardRequests(requests)
	if jumpCount != nil {
		jumpCount.Add(1)
	}
	go func() {
		io.Copy(upstream, channel)
		upstream.(*net.TCPConn).CloseWrite()
	}()
	io.Copy(channel, upstream)
}

func main() {
	if runtime.GOOS != "windows" || os.Getenv("GITHUB_ACTIONS") != "true" || len(os.Args) != 2 {
		panic("usage on a Windows GitHub Actions runner: sshfixture DESKLINK_EXE")
	}
	current := must(user.Current())
	work := must(os.MkdirTemp("", "desklink-ssh-"))
	defer os.RemoveAll(work)
	sshDir := filepath.Join(current.HomeDir, ".ssh")
	check(os.MkdirAll(sshDir, 0700))
	configPath := filepath.Join(sshDir, "config")
	if _, err := os.Stat(configPath); !errors.Is(err, os.ErrNotExist) {
		panic("Windows SSH fixture requires a fresh runner without an SSH config")
	}

	_, clientKey, err := ed25519.GenerateKey(rand.Reader)
	check(err)
	clientSigner := must(ssh.NewSignerFromKey(clientKey))
	privateKey := filepath.Join(work, "identity")
	check(os.WriteFile(privateKey, pem.EncodeToMemory(must(ssh.MarshalPrivateKey(clientKey, "desklink-fixture"))), 0600))
	if output, err := exec.Command("icacls.exe", privateKey, "/inheritance:r", "/grant:r", "*"+current.Uid+":F").CombinedOutput(); err != nil {
		panic(fmt.Errorf("restrict test key access: %w: %s", err, output))
	}
	_, hostKey, err := ed25519.GenerateKey(rand.Reader)
	check(err)
	hostSigner := must(ssh.NewSignerFromKey(hostKey))
	serverConfig := &ssh.ServerConfig{PublicKeyCallback: func(conn ssh.ConnMetadata, key ssh.PublicKey) (*ssh.Permissions, error) {
		if (conn.User() != "fixture" && conn.User() != "fixture-tunnel") || !bytes.Equal(key.Marshal(), clientSigner.PublicKey().Marshal()) {
			return nil, errors.New("unexpected fixture login")
		}
		return nil, nil
	}}
	serverConfig.AddHostKey(hostSigner)

	jump, target, backend := listener(), listener(), listener()
	defer jump.Close()
	defer target.Close()
	defer backend.Close()
	var jumps atomic.Int32
	go serve(jump, serverConfig, target.Addr().String(), &jumps)
	go serve(target, serverConfig, backend.Addr().String(), nil)
	go func() {
		conn, err := backend.Accept()
		if err == nil {
			defer conn.Close()
			io.WriteString(conn, marker)
		}
	}()

	hostsPath := filepath.Join(work, "known_hosts")
	hostLine := func(l net.Listener) string {
		return fmt.Sprintf("[127.0.0.1]:%d %s", l.Addr().(*net.TCPAddr).Port, ssh.MarshalAuthorizedKey(hostSigner.PublicKey()))
	}
	check(os.WriteFile(hostsPath, []byte(hostLine(jump)+hostLine(target)), 0600))
	sshConfig := must(os.OpenFile(configPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600))
	defer os.Remove(configPath)
	_, err = fmt.Fprintf(sshConfig, `Host desklink-jump
  HostName 127.0.0.1
  Port %d
Host desklink-tunnel-target
  User fixture-tunnel
Host desklink-target desklink-tunnel-target
  HostName 127.0.0.1
  Port %d
  ProxyJump desklink-jump
Host *
  User fixture
  IdentityFile "%s"
  UserKnownHostsFile "%s"
  StrictHostKeyChecking yes
  IdentitiesOnly yes
  BatchMode yes
  ConnectTimeout 5
`, jump.Addr().(*net.TCPAddr).Port, target.Addr().(*net.TCPAddr).Port, filepath.ToSlash(privateKey), filepath.ToSlash(hostsPath))
	closeErr := sshConfig.Close()
	check(err)
	check(closeErr)

	local := listener()
	localAddr, localPort := local.Addr().String(), local.Addr().(*net.TCPAddr).Port
	local.Close()
	config := map[string]any{"devices": []map[string]any{{
		"name": "smoke", "id": "123456789", "address": backend.Addr().String(), "ssh": "desklink-target",
		"ssh_tunnel": "desklink-tunnel-target", "ssh_local_port": localPort,
	}}}
	appConfig := filepath.Join(work, "desklink.json")
	check(os.WriteFile(appConfig, must(json.Marshal(config)), 0600))
	cli := os.Args[1]
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, cli, "-config", appConfig, "ssh", "smoke", "hostname").CombinedOutput()
	if err != nil || strings.TrimSpace(string(out)) != "desklink-test-host" {
		panic(fmt.Errorf("SSH command: %v: %s", err, out))
	}
	fmt.Println("PASS Windows OpenSSH authenticates over ProxyJump and executes hostname")

	tunnel := exec.Command(cli, "-config", appConfig, "tunnel", "smoke")
	tunnel.Stdout, tunnel.Stderr = os.Stdout, os.Stderr
	check(tunnel.Start())
	defer func() {
		exec.Command("taskkill.exe", "/PID", strconv.Itoa(tunnel.Process.Pid), "/T", "/F").Run()
		tunnel.Wait()
	}()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("tcp4", localAddr, 250*time.Millisecond)
		if err != nil {
			time.Sleep(100 * time.Millisecond)
			continue
		}
		conn.SetReadDeadline(time.Now().Add(5 * time.Second))
		b := make([]byte, len(marker))
		_, err = io.ReadFull(conn, b)
		conn.Close()
		if err != nil || string(b) != marker || jumps.Load() < 2 {
			panic(fmt.Errorf("SSH tunnel data %q, jump sessions %d: %v", b, jumps.Load(), err))
		}
		fmt.Println("PASS Windows SSH tunnel forwards bytes to the separate private address through ProxyJump")
		return
	}
	panic("desktop tunnel did not start")
}
