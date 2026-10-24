package diagnosis

import (
	"fmt"

	models "github.com/victor-octavio/telehealth-audit-api/gateway/internal/models/diagnosis"
	"github.com/victor-octavio/telehealth-audit-api/gateway/internal/repositories"
)

type IDiagnosis interface {
	GetById(orgName, ID string) (*models.DiagnosisRequest, error)
	GetHistory(orgName, ID string) ([]models.HistoryEntry, error)
	Add(orgName string, req models.DiagnosisRequest) error
	Update(orgName, id string, req models.UpdateRequest) error
}

type DiagnosisImpl struct {
	Repository *repositories.Repositories
}

func New(repo *repositories.Repositories) IDiagnosis {
	return &DiagnosisImpl{
		Repository: repo,
	}
}

func (d *DiagnosisImpl) Add(orgName string, req models.DiagnosisRequest) error {
	if req.ID == "" {
		return fmt.Errorf("%w: id is required", models.ErrInvalidInput)
	}
	return d.Repository.Diagnosis.Add(orgName, req)
}

func (d *DiagnosisImpl) Update(orgName, id string, req models.UpdateRequest) error {
	if !req.NewStatus.Valid() {
		return fmt.Errorf("%w: new_status must be OPEN, UNDER_REVIEW or CLOSED", models.ErrInvalidInput)
	}
	return d.Repository.Diagnosis.Update(orgName, id, req)
}

func (d *DiagnosisImpl) GetHistory(orgName, ID string) ([]models.HistoryEntry, error) {
	return d.Repository.Diagnosis.GetHistory(orgName, ID)
}

func (d *DiagnosisImpl) GetById(orgName, ID string) (*models.DiagnosisRequest, error) {
	return d.Repository.Diagnosis.GetById(orgName, ID)
}
