package repositories

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/hyperledger/fabric-protos-go-apiv2/gateway"
	models "github.com/victor-octavio/telehealth-audit-api/gateway/internal/models/diagnosis"
	"github.com/victor-octavio/telehealth-audit-api/gateway/pkg/fabric"
	"google.golang.org/grpc/status"
)

type DiagnosisRepository struct {
	gateway *fabric.MultiGateway
}

func New(gw *fabric.MultiGateway) *DiagnosisRepository {
	return &DiagnosisRepository{gateway: gw}
}

func (d *DiagnosisRepository) GetById(orgName, ID string) (*models.DiagnosisRequest, error) {
	contract, err := d.gateway.Contract(orgName)
	if err != nil {
		return nil, err
	}

	record, err := contract.EvaluateTransaction("ReadDiagnosis", ID)
	if err != nil {
		return nil, translateError("error during record fetch", err)
	}

	var result models.DiagnosisRequest
	if err := json.Unmarshal(record, &result); err != nil {
		return nil, fmt.Errorf("error during json decoding")
	}
	return &result, nil
}

func (d *DiagnosisRepository) GetHistory(orgName, ID string) ([]models.HistoryEntry, error) {
	contract, err := d.gateway.Contract(orgName)
	if err != nil {
		return nil, err
	}

	history, err := contract.EvaluateTransaction("GetHistory", ID)
	if err != nil {
		return nil, translateError("error during GetHistory request", err)
	}

	var result []models.HistoryEntry
	if err := json.Unmarshal(history, &result); err != nil {
		return nil, fmt.Errorf("error during json decoding")
	}
	return result, nil
}

func (d *DiagnosisRepository) Add(orgName string, req models.DiagnosisRequest) error {
	contract, err := d.gateway.Contract(orgName)
	if err != nil {
		return err
	}

	_, err = contract.SubmitTransaction(
		"InsertDiagnostic",
		req.ID,
		req.PatientID,
		req.PhysicianID,
		req.Diagnosis,
		req.Observation,
		req.Severity,
		req.AttendanceType,
		req.Location,
		req.AttachmentHash,
	)
	if err != nil {
		return translateError("error during transaction", err)
	}
	return nil
}

func (d *DiagnosisRepository) Update(orgName, id string, req models.UpdateRequest) error {
	contract, err := d.gateway.Contract(orgName)
	if err != nil {
		return err
	}

	_, err = contract.SubmitTransaction(
		"UpdateDiagnostic",
		id,
		string(req.NewStatus),
		req.Diagnosis,
		req.Observation,
		req.Severity,
		req.AttendanceType,
		req.Location,
		req.AttachmentHash,
	)
	if err != nil {
		return translateError("error during update transaction", err)
	}
	return nil
}

// translateError extracts the chaincode message from a Fabric Gateway error and wraps it
// in the matching domain error, so handlers can answer with a meaningful HTTP status.
func translateError(context string, err error) error {
	msg := chaincodeMessage(err)

	var sentinel error
	switch {
	case strings.Contains(msg, "permission denied"):
		sentinel = models.ErrPermissionDenied
	case strings.Contains(msg, "invalid status transition"):
		sentinel = models.ErrInvalidTransition
	case strings.Contains(msg, "invalid severity"), strings.Contains(msg, "invalid attendance type"):
		sentinel = models.ErrInvalidInput
	case strings.Contains(msg, "not found"):
		sentinel = models.ErrNotFound
	case strings.Contains(msg, "already exists"):
		sentinel = models.ErrAlreadyExists
	default:
		return fmt.Errorf("%s: %s", context, msg)
	}
	return fmt.Errorf("%w: %s", sentinel, msg)
}

func chaincodeMessage(err error) string {
	st := status.Convert(err)
	var parts []string
	for _, detail := range st.Details() {
		if ed, ok := detail.(*gateway.ErrorDetail); ok && ed.GetMessage() != "" {
			parts = append(parts, ed.GetMessage())
		}
	}
	if len(parts) == 0 {
		return st.Message()
	}
	return strings.Join(parts, "; ")
}
