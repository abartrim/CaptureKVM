package control

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"sync"
	"time"
)

var ErrSessionNotFound = errors.New("session not found")

type Session struct {
	ID        uint64
	Key       [32]byte
	CreatedAt time.Time
	LastSeen  time.Time
	ExpiresAt time.Time
}

func (s Session) IDString() string {
	var buf [8]byte
	binary.BigEndian.PutUint64(buf[:], s.ID)
	return hex.EncodeToString(buf[:])
}

func (s Session) KeyBase64() string {
	return base64.StdEncoding.EncodeToString(s.Key[:])
}

type Manager struct {
	mu       sync.Mutex
	ttl      time.Duration
	now      func() time.Time
	sessions map[uint64]*Session
}

func NewManager(ttl time.Duration) *Manager {
	return &Manager{
		ttl:      ttl,
		now:      time.Now,
		sessions: make(map[uint64]*Session),
	}
}

func (m *Manager) Create() (*Session, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.reapLocked()

	now := m.now()
	session := &Session{
		ID:        randomUint64(),
		CreatedAt: now,
		LastSeen:  now,
		ExpiresAt: now.Add(m.ttl),
	}
	if _, err := rand.Read(session.Key[:]); err != nil {
		return nil, err
	}
	m.sessions[session.ID] = session
	return cloneSession(session), nil
}

func (m *Manager) KeepAlive(id uint64) (*Session, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.reapLocked()

	session, ok := m.sessions[id]
	if !ok {
		return nil, ErrSessionNotFound
	}
	now := m.now()
	session.LastSeen = now
	session.ExpiresAt = now.Add(m.ttl)
	return cloneSession(session), nil
}

func (m *Manager) Get(id uint64) (*Session, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.reapLocked()

	session, ok := m.sessions[id]
	if !ok {
		return nil, false
	}
	return cloneSession(session), true
}

func (m *Manager) Close(id uint64) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	_, ok := m.sessions[id]
	delete(m.sessions, id)
	return ok
}

func (m *Manager) Count() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.reapLocked()
	return len(m.sessions)
}

func (m *Manager) reapLocked() {
	now := m.now()
	for id, session := range m.sessions {
		if !session.ExpiresAt.After(now) {
			delete(m.sessions, id)
		}
	}
}

func cloneSession(s *Session) *Session {
	copy := *s
	return &copy
}

func randomUint64() uint64 {
	var buf [8]byte
	if _, err := rand.Read(buf[:]); err != nil {
		panic(err)
	}
	return binary.BigEndian.Uint64(buf[:])
}

func ParseSessionID(value string) (uint64, error) {
	raw, err := hex.DecodeString(value)
	if err != nil {
		return 0, err
	}
	if len(raw) != 8 {
		return 0, errors.New("session_id must be 16 hex characters")
	}
	return binary.BigEndian.Uint64(raw), nil
}
