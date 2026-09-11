package tailnetandroid

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"tailscale.com/ipn/ipnstate"
	"tailscale.com/net/netmon"
	"tailscale.com/tsnet"
)

const (
	tailnetStartupTimeout = 10 * time.Second
	tailnetStatusTimeout  = 2 * time.Second
)

// Service owns a single persisted tsnet node and loopback HTTP relays.
type Service struct {
	mu         sync.Mutex
	server     *tsnet.Server
	stateDir   string
	interfaces []netmon.Interface
}

type connectionStatus struct {
	BaseURL      string `json:"baseUrl,omitempty"`
	BackendState string `json:"backendState"`
	AuthURL      string `json:"authUrl,omitempty"`
}

type androidInterface struct {
	Name       string   `json:"name"`
	Index      int      `json:"index"`
	MTU        int      `json:"mtu"`
	IsUp       bool     `json:"isUp"`
	IsLoopback bool     `json:"isLoopback"`
	Addresses  []string `json:"addresses"`
}

// NewService creates the Go Mobile entry point used by the Android host.
func NewService() *Service {
	s := &Service{}
	netmon.RegisterInterfaceGetter(s.getInterfaces)
	return s
}

// SetInterfacesJSON accepts the Android-visible network interfaces before
// tsnet starts. Android app UIDs cannot enumerate routing state via netlink.
func (s *Service) SetInterfacesJSON(raw string) error {
	var source []androidInterface
	if err := json.Unmarshal([]byte(raw), &source); err != nil {
		return fmt.Errorf("decode Android interfaces: %w", err)
	}
	interfaces := make([]netmon.Interface, 0, len(source))
	for _, item := range source {
		if strings.TrimSpace(item.Name) == "" {
			continue
		}
		addrs := make([]net.Addr, 0, len(item.Addresses))
		for _, rawAddress := range item.Addresses {
			prefix, err := netip.ParsePrefix(rawAddress)
			if err != nil {
				return fmt.Errorf("decode address for %s: %w", item.Name, err)
			}
			addrs = append(addrs, &net.IPNet{
				IP:   net.IP(prefix.Addr().AsSlice()),
				Mask: net.CIDRMask(prefix.Bits(), prefix.Addr().BitLen()),
			})
		}
		flags := net.Flags(0)
		if item.IsUp {
			flags |= net.FlagUp
		}
		if item.IsLoopback {
			flags |= net.FlagLoopback
		}
		interfaces = append(interfaces, netmon.Interface{
			Interface: &net.Interface{
				Index: item.Index,
				MTU:   item.MTU,
				Name:  item.Name,
				Flags: flags,
			},
			AltAddrs: addrs,
		})
	}
	if len(interfaces) == 0 {
		return errors.New("Android reported no network interfaces")
	}
	s.mu.Lock()
	s.interfaces = interfaces
	s.mu.Unlock()
	return nil
}

func (s *Service) getInterfaces() ([]netmon.Interface, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.interfaces) == 0 {
		return nil, errors.New("Android network interfaces are unavailable")
	}
	interfaces := make([]netmon.Interface, len(s.interfaces))
	copy(interfaces, s.interfaces)
	return interfaces, nil
}

// Connect starts tsnet when needed and returns a loopback HTTP endpoint that
// relays a single client connection to target on the tailnet.
func (s *Service) Connect(stateDir, target string) (string, error) {
	if err := validateTarget(target); err != nil {
		return "", err
	}
	server, pendingStatus, err := s.start(stateDir)
	if err != nil {
		return "", err
	}
	if pendingStatus != "" {
		return pendingStatus, nil
	}

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return "", fmt.Errorf("start loopback relay: %w", err)
	}
	go s.serveOnce(listener, server, target)
	return s.statusJSON(server, "http://"+listener.Addr().String())
}

// Authorize starts tsnet without opening a relay so the host app can direct
// the user to Tailscale's interactive authorization URL.
func (s *Service) Authorize(stateDir string) (string, error) {
	server, pendingStatus, err := s.start(stateDir)
	if err != nil {
		return "", err
	}
	if pendingStatus != "" {
		return pendingStatus, nil
	}
	return s.statusJSON(server, "")
}

func (s *Service) start(stateDir string) (*tsnet.Server, string, error) {
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		return nil, "", fmt.Errorf("create Tailscale state directory: %w", err)
	}
	if err := os.Setenv("TS_LOGS_DIR", stateDir); err != nil {
		return nil, "", fmt.Errorf("configure Tailscale log directory: %w", err)
	}

	s.mu.Lock()
	if s.server == nil {
		s.server = &tsnet.Server{
			Dir:      filepath.Clean(stateDir),
			Hostname: "nas-reader",
		}
		s.stateDir = stateDir
	} else if s.stateDir != stateDir {
		s.mu.Unlock()
		return nil, "", fmt.Errorf("Tailscale state directory changed while active")
	}
	server := s.server
	s.mu.Unlock()

	if err := server.Start(); err != nil {
		return nil, "", fmt.Errorf("connect to Tailnet: %w", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), tailnetStartupTimeout)
	defer cancel()
	if _, err := server.Up(ctx); err != nil {
		if errors.Is(err, context.DeadlineExceeded) {
			status, statusErr := s.statusJSON(server, "")
			return server, status, statusErr
		}
		return nil, "", fmt.Errorf("connect to Tailnet: %w", err)
	}
	return server, "", nil
}

func (s *Service) serveOnce(listener net.Listener, server *tsnet.Server, target string) {
	defer listener.Close()
	local, err := listener.Accept()
	if err != nil {
		return
	}
	defer local.Close()

	remote, err := server.Dial(context.Background(), "tcp", target)
	if err != nil {
		return
	}
	defer remote.Close()

	done := make(chan struct{}, 2)
	go func() {
		_, _ = io.Copy(remote, local)
		done <- struct{}{}
	}()
	go func() {
		_, _ = io.Copy(local, remote)
		done <- struct{}{}
	}()
	<-done
}

func validateTarget(target string) error {
	if strings.TrimSpace(target) != target || target == "" {
		return fmt.Errorf("Tailnet target is required")
	}
	if _, _, err := net.SplitHostPort(target); err != nil {
		return fmt.Errorf("invalid Tailnet target: %w", err)
	}
	return nil
}

// Status starts the persisted node when necessary and returns its current
// backend state and any interactive authorization URL.
func (s *Service) Status(stateDir string) (string, error) {
	server, pendingStatus, err := s.start(stateDir)
	if err != nil {
		return "", err
	}
	if pendingStatus != "" {
		return pendingStatus, nil
	}
	return s.statusJSON(server, "")
}

// Logout removes the current node's Tailnet authorization and closes tsnet.
func (s *Service) Logout() error {
	s.mu.Lock()
	server := s.server
	s.server = nil
	s.stateDir = ""
	s.mu.Unlock()
	if server == nil {
		return nil
	}

	client, err := server.LocalClient()
	if err == nil {
		ctx, cancel := context.WithTimeout(context.Background(), tailnetStatusTimeout)
		err = client.Logout(ctx)
		cancel()
	}
	closeErr := server.Close()
	if err != nil {
		return fmt.Errorf("log out from Tailnet: %w", err)
	}
	return closeErr
}

func (s *Service) statusJSON(server *tsnet.Server, baseURL string) (string, error) {
	client, err := server.LocalClient()
	if err != nil {
		return "", err
	}
	ctx, cancel := context.WithTimeout(context.Background(), tailnetStatusTimeout)
	defer cancel()
	status, err := client.Status(ctx)
	if err != nil {
		return "", err
	}
	return marshalStatus(statusFromTailscale(status, baseURL))
}

func statusFromTailscale(status *ipnstate.Status, baseURL string) connectionStatus {
	return connectionStatus{
		BaseURL:      baseURL,
		BackendState: status.BackendState,
		AuthURL:      status.AuthURL,
	}
}

func marshalStatus(status connectionStatus) (string, error) {
	encoded, err := json.Marshal(status)
	if err != nil {
		return "", fmt.Errorf("encode Tailnet status: %w", err)
	}
	return string(encoded), nil
}

// Close releases tsnet resources during Android activity teardown.
func (s *Service) Close() error {
	s.mu.Lock()
	server := s.server
	s.server = nil
	s.stateDir = ""
	s.mu.Unlock()
	if server == nil {
		return nil
	}
	return server.Close()
}
