package auth

import (
	"encoding/json"
	"net/http"
	"strings"
)

func Middleware(token string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !Authorized(r, token) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusUnauthorized)
			_ = json.NewEncoder(w).Encode(map[string]any{
				"ok":    false,
				"error": "unauthorized",
			})
			return
		}
		next.ServeHTTP(w, r)
	})
}

func Authorized(r *http.Request, token string) bool {
	if strings.TrimSpace(token) == "" {
		return false
	}
	authz := strings.TrimSpace(r.Header.Get("Authorization"))
	if strings.HasPrefix(strings.ToLower(authz), "bearer ") {
		return strings.TrimSpace(authz[7:]) == token
	}
	return strings.TrimSpace(r.Header.Get("X-CaptureKVM-Token")) == token
}
