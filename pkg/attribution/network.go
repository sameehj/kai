package attribution

import (
	"net"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/kai-ai/kai/pkg/storage"
)

type cacheEntry struct {
	domain string
	expiry time.Time
}

type DNSCache struct {
	mu    sync.RWMutex
	mem   map[string]cacheEntry // keys: ip OR ip:port
	store *storage.DB
}

func NewDNSCache(store *storage.DB) *DNSCache {
	return &DNSCache{mem: map[string]cacheEntry{}, store: store}
}

func (c *DNSCache) Set(ip, domain string, ttl time.Duration) {
	c.mu.Lock()
	c.mem[ip] = cacheEntry{domain: domain, expiry: time.Now().Add(ttl)}
	c.mu.Unlock()
	if c.store != nil {
		_ = c.store.SetDNSEntry(ip, domain, ttl)
	}
}

func (c *DNSCache) SetEndpoint(ip string, port int, domain string, ttl time.Duration) {
	if ip == "" || port <= 0 {
		return
	}
	key := endpointKey(ip, port)
	c.mu.Lock()
	c.mem[key] = cacheEntry{domain: domain, expiry: time.Now().Add(ttl)}
	c.mu.Unlock()
}

func (c *DNSCache) Get(ip string) (string, bool) {
	c.mu.RLock()
	v, ok := c.mem[ip]
	c.mu.RUnlock()
	if ok && time.Now().Before(v.expiry) {
		return v.domain, true
	}
	if c.store != nil {
		if d, ok := c.store.GetDNSEntry(ip); ok {
			c.Set(ip, d, 5*time.Minute)
			return d, true
		}
	}
	return "", false
}

func PreResolveKnownDomains(cache *DNSCache) {
	for domain := range KnownAIDomains {
		d := domain
		go func() {
			host, port := splitDomainPort(d)
			ips, err := net.LookupHost(host)
			if err != nil {
				return
			}
			for _, ip := range ips {
				cache.Set(ip, d, 10*time.Minute)
				if port > 0 {
					cache.SetEndpoint(ip, port, d, 10*time.Minute)
				}
			}
		}()
	}
}

func (c *DNSCache) ResolveIP(ip string, port int) (*string, bool) {
	if port > 0 {
		if d, ok := c.getEndpoint(ip, port); ok {
			isAI := isKnownAIDomain(d)
			return &d, isAI
		}
	}
	if d, ok := c.Get(ip); ok {
		isAI := isKnownAIDomain(d)
		return &d, isAI
	}
	go func() {
		names, err := net.LookupAddr(ip)
		if err == nil && len(names) > 0 {
			d := strings.TrimSuffix(names[0], ".")
			c.Set(ip, d, 5*time.Minute)
		}
	}()
	return nil, false
}

func (c *DNSCache) getEndpoint(ip string, port int) (string, bool) {
	key := endpointKey(ip, port)
	c.mu.RLock()
	v, ok := c.mem[key]
	c.mu.RUnlock()
	if ok && time.Now().Before(v.expiry) {
		return v.domain, true
	}
	return "", false
}

func endpointKey(ip string, port int) string {
	return ip + ":" + strconv.Itoa(port)
}

func splitDomainPort(v string) (string, int) {
	s := strings.TrimSpace(v)
	if s == "" {
		return "", 0
	}
	if h, p, err := net.SplitHostPort(s); err == nil {
		port, _ := strconv.Atoi(p)
		return strings.Trim(h, "[]"), port
	}
	if i := strings.LastIndex(s, ":"); i > 0 && i < len(s)-1 && strings.Count(s, ":") == 1 {
		port, err := strconv.Atoi(s[i+1:])
		if err == nil {
			return s[:i], port
		}
	}
	return s, 0
}

func isKnownAIDomain(d string) bool {
	_, ok := AgentForDomain(d)
	return ok
}
