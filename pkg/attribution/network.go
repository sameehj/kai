package attribution

import (
	"net"
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
	mem   map[string]cacheEntry
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
			host := strings.Split(d, ":")[0]
			ips, err := net.LookupHost(host)
			if err != nil {
				return
			}
			for _, ip := range ips {
				cache.Set(ip, d, 10*time.Minute)
			}
		}()
	}
}

func (c *DNSCache) ResolveIP(ip string) (*string, bool) {
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

func isKnownAIDomain(d string) bool {
	_, ok := AgentForDomain(d)
	return ok
}
