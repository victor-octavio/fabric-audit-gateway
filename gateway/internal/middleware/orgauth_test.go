package middleware

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
)

func TestOrgIdentifier(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.GET("/", OrgIdentifier([]string{"emergency", "hospital", "audit"}), func(c *gin.Context) {
		c.String(http.StatusOK, c.GetString(OrgKey))
	})

	cases := []struct {
		name, header, query string
		code                int
		body                string
	}{
		{"header", "hospital", "", http.StatusOK, "hospital"},
		{"query", "", "?org=audit", http.StatusOK, "audit"},
		{"missing", "", "", http.StatusBadRequest, ""},
		{"unknown", "samu", "", http.StatusBadRequest, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, "/"+tc.query, nil)
			if tc.header != "" {
				req.Header.Set("X-Org", tc.header)
			}
			rec := httptest.NewRecorder()
			router.ServeHTTP(rec, req)
			if rec.Code != tc.code {
				t.Fatalf("status = %d, want %d", rec.Code, tc.code)
			}
			if tc.body != "" && rec.Body.String() != tc.body {
				t.Fatalf("org = %q, want %q", rec.Body.String(), tc.body)
			}
		})
	}
}
