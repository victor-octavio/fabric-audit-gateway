package models

type Status string

const (
	StatusOpen        Status = "OPEN"
	StatusUnderReview Status = "UNDER_REVIEW"
	StatusClosed      Status = "CLOSED"
)

func (s Status) Valid() bool {
	return s == StatusOpen || s == StatusUnderReview || s == StatusClosed
}

type DiagnosisRequest struct {
	ID             string `json:"id,omitempty"`
	PatientID      string `json:"patient_id,omitempty"`
	PhysicianID    string `json:"physician_id,omitempty"`
	Diagnosis      string `json:"diagnosis,omitempty"`
	Observation    string `json:"observation,omitempty"`
	Status         Status `json:"status,omitempty"`
	Severity       string `json:"severity,omitempty"`
	AttendanceType string `json:"attendance_type,omitempty"`
	Location       string `json:"location,omitempty"`
	AttachmentHash string `json:"attachment_hash,omitempty"`
	CreatedAt      string `json:"created_at,omitempty"`
	UpdatedAt      string `json:"updated_at,omitempty"`
	CreatedBy      string `json:"created_by,omitempty"`
	UpdatedBy      string `json:"updated_by,omitempty"`
}

// UpdateRequest moves a record to NewStatus. Omitted fields keep their stored value.
type UpdateRequest struct {
	NewStatus      Status `json:"new_status"`
	Diagnosis      string `json:"diagnosis,omitempty"`
	Observation    string `json:"observation,omitempty"`
	Severity       string `json:"severity,omitempty"`
	AttendanceType string `json:"attendance_type,omitempty"`
	Location       string `json:"location,omitempty"`
	AttachmentHash string `json:"attachment_hash,omitempty"`
}

// HistoryEntry is one ledger modification of a record, with its transaction metadata.
type HistoryEntry struct {
	TxID      string            `json:"tx_id"`
	Timestamp string            `json:"timestamp"`
	IsDelete  bool              `json:"is_delete"`
	Record    *DiagnosisRequest `json:"record,omitempty"`
}
