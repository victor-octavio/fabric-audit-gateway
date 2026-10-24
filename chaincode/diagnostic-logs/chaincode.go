package main

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/hyperledger/fabric-contract-api-go/contractapi"
)

const (
	// MSP IDs allowed to write. Org3MSP (audit) is read-only.
	mspEmergency = "Org1MSP"
	mspHospital  = "Org2MSP"
)

type SmartContract struct {
	contractapi.Contract
}

type Status string

const (
	StatusOpen        Status = "OPEN"
	StatusUnderReview Status = "UNDER_REVIEW"
	StatusClosed      Status = "CLOSED"
)

var validTransitions = map[Status][]Status{
	StatusOpen:        {StatusUnderReview},
	StatusUnderReview: {StatusClosed},
	StatusClosed:      {},
}

// Manchester triage colors.
var validSeverities = map[string]bool{
	"red": true, "orange": true, "yellow": true, "green": true, "blue": true,
}

var validAttendanceTypes = map[string]bool{
	"trauma": true, "stroke": true, "ami": true, "respiratory": true, "other": true,
}

type DiagnosticRecord struct {
	ID             string `json:"id,omitempty"`
	PatientID      string `json:"patient_id,omitempty"`
	PhysicianID    string `json:"physician_id,omitempty"`
	Diagnosis      string `json:"diagnosis,omitempty"`
	Observation    string `json:"observation,omitempty"`
	Status         Status `json:"status,omitempty"`
	Severity       string `json:"severity,omitempty"`        // Manchester color
	AttendanceType string `json:"attendance_type,omitempty"` // trauma, stroke, ami, respiratory, other
	Location       string `json:"location,omitempty"`        // coordinates or address of the attendance
	AttachmentHash string `json:"attachment_hash,omitempty"` // SHA-256 of an off-chain attachment (hash only)
	CreatedAt      string `json:"created_at,omitempty"`
	UpdatedAt      string `json:"updated_at,omitempty"`
	CreatedBy      string `json:"created_by,omitempty"` // MSP ID of the creator
	UpdatedBy      string `json:"updated_by,omitempty"` // MSP ID of the last updater
}

// HistoryEntry is one ledger modification of a record, with its transaction metadata.
type HistoryEntry struct {
	TxID      string            `json:"tx_id"`
	Timestamp string            `json:"timestamp"`
	IsDelete  bool              `json:"is_delete"`
	Record    *DiagnosticRecord `json:"record,omitempty"`
}

// requireMSP returns the caller's MSP ID, or a permission error when it is not the allowed one.
func requireMSP(ctx contractapi.TransactionContextInterface, allowed string) (string, error) {
	mspID, err := ctx.GetClientIdentity().GetMSPID()
	if err != nil {
		return "", fmt.Errorf("failed to get MSP ID: %w", err)
	}
	if mspID != allowed {
		return "", fmt.Errorf("permission denied: organization %s cannot perform this operation", mspID)
	}
	return mspID, nil
}

// txTime returns the transaction timestamp as RFC3339. It comes from the signed proposal, so every
// endorser computes the same value. time.Now() must not be used here: each endorser would read its own
// clock, the write sets would differ and the endorsements would be rejected as mismatched.
func txTime(ctx contractapi.TransactionContextInterface) (string, error) {
	ts, err := ctx.GetStub().GetTxTimestamp()
	if err != nil {
		return "", fmt.Errorf("failed to get transaction timestamp: %w", err)
	}
	return ts.AsTime().UTC().Format(time.RFC3339), nil
}

func validateClassification(severity, attendanceType string) error {
	if severity != "" && !validSeverities[severity] {
		return fmt.Errorf("invalid severity %q: must be red, orange, yellow, green or blue", severity)
	}
	if attendanceType != "" && !validAttendanceTypes[attendanceType] {
		return fmt.Errorf("invalid attendance type %q: must be trauma, stroke, ami, respiratory or other", attendanceType)
	}
	return nil
}

// InsertDiagnostic creates a record in OPEN status. Only the emergency organization (Org1MSP) may call it.
func (s *SmartContract) InsertDiagnostic(ctx contractapi.TransactionContextInterface, id, patientId, physicianId, diagnosis, observation, severity, attendanceType, location, attachmentHash string) error {
	mspID, err := requireMSP(ctx, mspEmergency)
	if err != nil {
		return err
	}
	if err := validateClassification(severity, attendanceType); err != nil {
		return err
	}

	exists, err := s.DiagnosticExists(ctx, id)
	if err != nil {
		return err
	}
	if exists {
		return fmt.Errorf("diagnosis %s already exists", id)
	}

	now, err := txTime(ctx)
	if err != nil {
		return err
	}
	record := DiagnosticRecord{
		ID:             id,
		PatientID:      patientId,
		PhysicianID:    physicianId,
		Diagnosis:      diagnosis,
		Observation:    observation,
		Status:         StatusOpen,
		Severity:       severity,
		AttendanceType: attendanceType,
		Location:       location,
		AttachmentHash: attachmentHash,
		CreatedAt:      now,
		UpdatedAt:      now,
		CreatedBy:      mspID,
		UpdatedBy:      mspID,
	}

	recordJson, err := json.Marshal(record)
	if err != nil {
		return err
	}
	return ctx.GetStub().PutState(id, recordJson)
}

// UpdateDiagnostic moves a record to newStatus and updates its clinical fields.
// Empty string arguments keep the stored value. Only the hospital organization (Org2MSP) may call it.
func (s *SmartContract) UpdateDiagnostic(ctx contractapi.TransactionContextInterface, id, newStatus, diagnosis, observation, severity, attendanceType, location, attachmentHash string) error {
	mspID, err := requireMSP(ctx, mspHospital)
	if err != nil {
		return err
	}
	if err := validateClassification(severity, attendanceType); err != nil {
		return err
	}

	record, err := s.ReadDiagnosis(ctx, id)
	if err != nil {
		return err
	}

	target := Status(newStatus)
	if !isValidTransition(record.Status, target) {
		return fmt.Errorf("invalid status transition: %s -> %s", record.Status, target)
	}

	record.Status = target
	setIfNotEmpty(&record.Diagnosis, diagnosis)
	setIfNotEmpty(&record.Observation, observation)
	setIfNotEmpty(&record.Severity, severity)
	setIfNotEmpty(&record.AttendanceType, attendanceType)
	setIfNotEmpty(&record.Location, location)
	setIfNotEmpty(&record.AttachmentHash, attachmentHash)
	updatedAt, err := txTime(ctx)
	if err != nil {
		return err
	}
	record.UpdatedAt = updatedAt
	record.UpdatedBy = mspID

	recordJson, err := json.Marshal(record)
	if err != nil {
		return err
	}
	return ctx.GetStub().PutState(id, recordJson)
}

func setIfNotEmpty(dst *string, value string) {
	if value != "" {
		*dst = value
	}
}

func isValidTransition(from, to Status) bool {
	for _, s := range validTransitions[from] {
		if s == to {
			return true
		}
	}
	return false
}

func (s *SmartContract) DiagnosticExists(ctx contractapi.TransactionContextInterface, id string) (bool, error) {
	record, err := ctx.GetStub().GetState(id)
	if err != nil {
		return false, err
	}
	return record != nil, nil
}

func (s *SmartContract) ReadDiagnosis(ctx contractapi.TransactionContextInterface, id string) (*DiagnosticRecord, error) {
	recordJson, err := ctx.GetStub().GetState(id)
	if err != nil {
		return nil, err
	}
	if recordJson == nil {
		return nil, fmt.Errorf("diagnosis not found, { id: %s }", id)
	}

	var record DiagnosticRecord
	if err := json.Unmarshal(recordJson, &record); err != nil {
		return nil, err
	}
	return &record, nil
}

// GetHistory returns every modification of a record with its transaction ID and timestamp.
func (s *SmartContract) GetHistory(ctx contractapi.TransactionContextInterface, id string) ([]*HistoryEntry, error) {
	historyIterator, err := ctx.GetStub().GetHistoryForKey(id)
	if err != nil {
		return nil, err
	}
	defer historyIterator.Close()

	var history []*HistoryEntry
	for historyIterator.HasNext() {
		entry, err := historyIterator.Next()
		if err != nil {
			return nil, err
		}

		item := &HistoryEntry{
			TxID:      entry.TxId,
			Timestamp: entry.Timestamp.AsTime().UTC().Format(time.RFC3339),
			IsDelete:  entry.IsDelete,
		}
		// a delete entry carries no value
		if !entry.IsDelete {
			var record DiagnosticRecord
			if err := json.Unmarshal(entry.Value, &record); err != nil {
				return nil, err
			}
			item.Record = &record
		}
		history = append(history, item)
	}
	return history, nil
}

func main() {
	chaincode, err := contractapi.NewChaincode(&SmartContract{})
	if err != nil {
		fmt.Printf("error creating chaincode, err = %v\n", err)
		return
	}
	if err := chaincode.Start(); err != nil {
		fmt.Printf("an error occurred during the chaincode start up")
	}
}
