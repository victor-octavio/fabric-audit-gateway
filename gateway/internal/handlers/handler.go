package handlers

import (
	"github.com/gin-gonic/gin"
	"github.com/victor-octavio/telehealth-audit-api/gateway/internal/handlers/diagnosis"
	"github.com/victor-octavio/telehealth-audit-api/gateway/internal/middleware"
	"github.com/victor-octavio/telehealth-audit-api/gateway/internal/usecases"
)

type Handler struct {
	engine *gin.Engine
}

type Options struct {
	UC       *usecases.Usecases
	OrgNames []string
}

func New(opts Options) *Handler {
	engine := gin.Default()
	diagnosis.Init(opts.UC, engine.Group("/diagnosis", middleware.OrgIdentifier(opts.OrgNames)))

	return &Handler{
		engine: engine,
	}
}

func (h *Handler) ListenAndServe() error {
	return h.engine.Run(":8090")
}
