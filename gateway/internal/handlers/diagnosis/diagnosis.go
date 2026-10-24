package diagnosis

import (
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/victor-octavio/telehealth-audit-api/gateway/internal/middleware"
	models "github.com/victor-octavio/telehealth-audit-api/gateway/internal/models/diagnosis"
	"github.com/victor-octavio/telehealth-audit-api/gateway/internal/usecases"
)

type DiagnosisHandler struct {
	uc *usecases.Usecases
}

// Init registers the diagnosis routes. The router group must run middleware.OrgIdentifier.
func Init(uc *usecases.Usecases, router *gin.RouterGroup) {
	dh := &DiagnosisHandler{uc: uc}

	router.POST("/insert", dh.Add)
	router.PUT("/update/:id", dh.Update)
	router.GET("/record/:id", dh.GetById)
	router.GET("/history/:id", dh.GetHistory)
}

func org(ctx *gin.Context) string {
	return ctx.GetString(middleware.OrgKey)
}

// respondError maps a domain error to its HTTP status; anything else uses fallback.
func respondError(ctx *gin.Context, fallback int, msg string, err error) {
	code := fallback
	switch {
	case errors.Is(err, models.ErrPermissionDenied):
		code = http.StatusForbidden
	case errors.Is(err, models.ErrInvalidTransition), errors.Is(err, models.ErrAlreadyExists):
		code = http.StatusConflict
	case errors.Is(err, models.ErrInvalidInput):
		code = http.StatusBadRequest
	case errors.Is(err, models.ErrNotFound):
		code = http.StatusNotFound
	}
	ctx.JSON(code, gin.H{"error": msg, "message": err.Error()})
}

func (dh *DiagnosisHandler) Add(ctx *gin.Context) {
	var req models.DiagnosisRequest
	if err := ctx.ShouldBindJSON(&req); err != nil {
		ctx.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body"})
		return
	}
	if err := dh.uc.Diagnosis.Add(org(ctx), req); err != nil {
		respondError(ctx, http.StatusInternalServerError, "failed to insert diagnosis", err)
		return
	}
	ctx.JSON(http.StatusCreated, gin.H{"id": req.ID, "message": "diagnosis record created in ledger"})
}

func (dh *DiagnosisHandler) Update(ctx *gin.Context) {
	var req models.UpdateRequest
	if err := ctx.ShouldBindJSON(&req); err != nil {
		ctx.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body"})
		return
	}
	if err := dh.uc.Diagnosis.Update(org(ctx), ctx.Param("id"), req); err != nil {
		respondError(ctx, http.StatusInternalServerError, "failed to update diagnosis", err)
		return
	}
	ctx.JSON(http.StatusOK, gin.H{"id": ctx.Param("id"), "status": req.NewStatus})
}

func (dh *DiagnosisHandler) GetById(ctx *gin.Context) {
	record, err := dh.uc.Diagnosis.GetById(org(ctx), ctx.Param("id"))
	if err != nil {
		respondError(ctx, http.StatusNotFound, "record not found", err)
		return
	}
	ctx.JSON(http.StatusOK, record)
}

func (dh *DiagnosisHandler) GetHistory(ctx *gin.Context) {
	history, err := dh.uc.Diagnosis.GetHistory(org(ctx), ctx.Param("id"))
	if err != nil {
		respondError(ctx, http.StatusBadRequest, "failed to fetch history", err)
		return
	}
	ctx.JSON(http.StatusOK, history)
}
