package repositories

import (
	models "github.com/victor-octavio/telehealth-audit-api/gateway/internal/models/diagnosis"
	repositories "github.com/victor-octavio/telehealth-audit-api/gateway/internal/repositories/diagnosis"
	"github.com/victor-octavio/telehealth-audit-api/gateway/pkg/fabric"
)

type Repositories struct {
	Diagnosis interface {
		GetById(orgName, ID string) (*models.DiagnosisRequest, error)
		GetHistory(orgName, ID string) ([]models.HistoryEntry, error)
		Add(orgName string, req models.DiagnosisRequest) error
		Update(orgName, id string, req models.UpdateRequest) error
	}
}

type Options struct {
	Gateway *fabric.MultiGateway
}

func New(opts Options) *Repositories {
	return &Repositories{
		Diagnosis: repositories.New(opts.Gateway),
	}
}
