package control

import (
	"testing"
	"time"
)

func TestSessionCreateAndKeepAlive(t *testing.T) {
	mgr := NewManager(2 * time.Second)

	session, err := mgr.Create()
	if err != nil {
		t.Fatalf("create failed: %v", err)
	}
	if session.ID == 0 {
		t.Fatal("expected non-zero session ID")
	}

	refreshed, err := mgr.KeepAlive(session.ID)
	if err != nil {
		t.Fatalf("keepalive failed: %v", err)
	}
	if !refreshed.ExpiresAt.After(session.ExpiresAt) && !refreshed.ExpiresAt.Equal(session.ExpiresAt) {
		t.Fatal("expected refreshed expiry")
	}
}

func TestSessionExpiry(t *testing.T) {
	mgr := NewManager(1 * time.Second)
	base := time.Unix(100, 0)
	mgr.now = func() time.Time { return base }

	session, err := mgr.Create()
	if err != nil {
		t.Fatalf("create failed: %v", err)
	}

	mgr.now = func() time.Time { return base.Add(2 * time.Second) }
	if _, ok := mgr.Get(session.ID); ok {
		t.Fatal("expected expired session to be removed")
	}
}
