package middleware

import (
	"net/http"
	"slices"

	"github.com/gin-gonic/gin"
)

// OrgKey is the gin context key holding the organization the request acts as.
const OrgKey = "org"

// OrgIdentifier reads the organization from the X-Org header (or the org query parameter)
// and rejects requests naming an organization the gateway is not configured for.
// It selects which Fabric identity signs the transaction; it is not authentication.
func OrgIdentifier(orgs []string) gin.HandlerFunc {
	return func(c *gin.Context) {
		org := c.GetHeader("X-Org")
		if org == "" {
			org = c.Query("org")
		}
		if org == "" {
			c.AbortWithStatusJSON(http.StatusBadRequest, gin.H{"error": "X-Org header or org query parameter is required"})
			return
		}
		if !slices.Contains(orgs, org) {
			c.AbortWithStatusJSON(http.StatusBadRequest, gin.H{"error": "unknown organization", "valid_orgs": orgs})
			return
		}
		c.Set(OrgKey, org)
		c.Next()
	}
}
