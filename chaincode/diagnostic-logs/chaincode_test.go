package main

import (
	"strings"
	"testing"
	"time"

	"github.com/hyperledger/fabric-chaincode-go/pkg/cid"
	"github.com/hyperledger/fabric-chaincode-go/shim"
	"github.com/hyperledger/fabric-protos-go/ledger/queryresult"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// fakeStub is an in-memory ledger that records every write as a history entry.
type fakeStub struct {
	shim.ChaincodeStubInterface
	state   map[string][]byte
	history map[string][]*queryresult.KeyModification
	txSeq   int
	txTime  time.Time
}

func newFakeStub() *fakeStub {
	return &fakeStub{state: map[string][]byte{}, history: map[string][]*queryresult.KeyModification{}, txTime: time.Unix(1700000000, 0)}
}

// GetTxTimestamp returns the same instant for every call on a stub, like the signed proposal does.
func (f *fakeStub) GetTxTimestamp() (*timestamppb.Timestamp, error) {
	return timestamppb.New(f.txTime), nil
}

func (f *fakeStub) GetState(key string) ([]byte, error) { return f.state[key], nil }

func (f *fakeStub) PutState(key string, value []byte) error {
	f.txSeq++
	f.state[key] = value
	f.history[key] = append(f.history[key], &queryresult.KeyModification{
		TxId:      "tx" + string(rune('0'+f.txSeq)),
		Value:     value,
		Timestamp: timestamppb.New(time.Unix(int64(1700000000+f.txSeq), 0)),
	})
	return nil
}

func (f *fakeStub) GetHistoryForKey(key string) (shim.HistoryQueryIteratorInterface, error) {
	return &fakeIterator{items: f.history[key]}, nil
}

type fakeIterator struct {
	items []*queryresult.KeyModification
	pos   int
}

func (i *fakeIterator) HasNext() bool { return i.pos < len(i.items) }
func (i *fakeIterator) Close() error  { return nil }
func (i *fakeIterator) Next() (*queryresult.KeyModification, error) {
	item := i.items[i.pos]
	i.pos++
	return item, nil
}

type fakeIdentity struct {
	cid.ClientIdentity
	msp string
}

func (f *fakeIdentity) GetMSPID() (string, error) { return f.msp, nil }

// fakeCtx implements contractapi.TransactionContextInterface for the tests.
type fakeCtx struct {
	stub *fakeStub
	id   *fakeIdentity
}

func (c *fakeCtx) GetStub() shim.ChaincodeStubInterface  { return c.stub }
func (c *fakeCtx) GetClientIdentity() cid.ClientIdentity { return c.id }

func as(stub *fakeStub, msp string) *fakeCtx {
	return &fakeCtx{stub: stub, id: &fakeIdentity{msp: msp}}
}

func insert(t *testing.T, s *SmartContract, ctx *fakeCtx, id string) {
	t.Helper()
	if err := s.InsertDiagnostic(ctx, id, "p1", "d1", "chest pain", "obs", "red", "ami", "-23.5,-46.6", "abc123"); err != nil {
		t.Fatalf("insert: %v", err)
	}
}

func TestInsertACL(t *testing.T) {
	s := &SmartContract{}
	for _, tc := range []struct {
		msp     string
		allowed bool
	}{{"Org1MSP", true}, {"Org2MSP", false}, {"Org3MSP", false}} {
		stub := newFakeStub()
		err := s.InsertDiagnostic(as(stub, tc.msp), "r1", "p", "d", "dx", "o", "red", "ami", "loc", "")
		if tc.allowed && err != nil {
			t.Errorf("%s: unexpected error %v", tc.msp, err)
		}
		if !tc.allowed && (err == nil || !strings.Contains(err.Error(), "permission denied")) {
			t.Errorf("%s: expected permission denied, got %v", tc.msp, err)
		}
	}
}

func TestInsertSetsInitialState(t *testing.T) {
	s, stub := &SmartContract{}, newFakeStub()
	insert(t, s, as(stub, "Org1MSP"), "r1")

	rec, err := s.ReadDiagnosis(as(stub, "Org3MSP"), "r1")
	if err != nil {
		t.Fatal(err)
	}
	if rec.Status != StatusOpen || rec.CreatedBy != "Org1MSP" || rec.UpdatedBy != "Org1MSP" || rec.AttachmentHash != "abc123" {
		t.Errorf("unexpected record: %+v", rec)
	}
	if err := s.InsertDiagnostic(as(stub, "Org1MSP"), "r1", "p", "d", "dx", "o", "", "", "", ""); err == nil {
		t.Error("expected duplicate insert to fail")
	}
}

func TestInsertValidation(t *testing.T) {
	s, stub := &SmartContract{}, newFakeStub()
	if err := s.InsertDiagnostic(as(stub, "Org1MSP"), "r1", "p", "d", "dx", "o", "purple", "ami", "", ""); err == nil {
		t.Error("expected invalid severity to fail")
	}
	if err := s.InsertDiagnostic(as(stub, "Org1MSP"), "r1", "p", "d", "dx", "o", "red", "burn", "", ""); err == nil {
		t.Error("expected invalid attendance type to fail")
	}
}

func TestUpdateACLAndTransitions(t *testing.T) {
	s, stub := &SmartContract{}, newFakeStub()
	insert(t, s, as(stub, "Org1MSP"), "r1")

	if err := s.UpdateDiagnostic(as(stub, "Org1MSP"), "r1", "UNDER_REVIEW", "", "", "", "", "", ""); err == nil || !strings.Contains(err.Error(), "permission denied") {
		t.Errorf("emergency must not update: %v", err)
	}
	if err := s.UpdateDiagnostic(as(stub, "Org3MSP"), "r1", "UNDER_REVIEW", "", "", "", "", "", ""); err == nil || !strings.Contains(err.Error(), "permission denied") {
		t.Errorf("audit must not update: %v", err)
	}

	hospital := as(stub, "Org2MSP")
	if err := s.UpdateDiagnostic(hospital, "r1", "CLOSED", "", "", "", "", "", ""); err == nil || !strings.Contains(err.Error(), "invalid status transition") {
		t.Errorf("OPEN -> CLOSED must fail: %v", err)
	}
	if err := s.UpdateDiagnostic(hospital, "r1", "UNDER_REVIEW", "confirmed AMI", "", "orange", "", "", ""); err != nil {
		t.Fatalf("OPEN -> UNDER_REVIEW: %v", err)
	}
	if err := s.UpdateDiagnostic(hospital, "r1", "CLOSED", "", "discharged", "", "", "", ""); err != nil {
		t.Fatalf("UNDER_REVIEW -> CLOSED: %v", err)
	}
	if err := s.UpdateDiagnostic(hospital, "r1", "OPEN", "", "", "", "", "", ""); err == nil {
		t.Error("CLOSED is final")
	}
}

func TestUpdateKeepsEmptyFields(t *testing.T) {
	s, stub := &SmartContract{}, newFakeStub()
	insert(t, s, as(stub, "Org1MSP"), "r1")
	if err := s.UpdateDiagnostic(as(stub, "Org2MSP"), "r1", "UNDER_REVIEW", "", "", "orange", "", "", ""); err != nil {
		t.Fatal(err)
	}
	rec, _ := s.ReadDiagnosis(as(stub, "Org3MSP"), "r1")
	if rec.Diagnosis != "chest pain" || rec.Observation != "obs" || rec.Location != "-23.5,-46.6" {
		t.Errorf("empty args must keep stored values: %+v", rec)
	}
	if rec.Severity != "orange" || rec.UpdatedBy != "Org2MSP" || rec.CreatedBy != "Org1MSP" {
		t.Errorf("unexpected metadata: %+v", rec)
	}
}

func TestGetHistory(t *testing.T) {
	s, stub := &SmartContract{}, newFakeStub()
	insert(t, s, as(stub, "Org1MSP"), "r1")
	_ = s.UpdateDiagnostic(as(stub, "Org2MSP"), "r1", "UNDER_REVIEW", "", "", "", "", "", "")

	history, err := s.GetHistory(as(stub, "Org3MSP"), "r1")
	if err != nil {
		t.Fatal(err)
	}
	if len(history) != 2 {
		t.Fatalf("expected 2 entries, got %d", len(history))
	}
	if history[0].TxID == "" || history[0].Timestamp == "" || history[0].Record.Status != StatusOpen {
		t.Errorf("bad first entry: %+v", history[0])
	}
	if history[1].Record.Status != StatusUnderReview || history[1].Record.UpdatedBy != "Org2MSP" {
		t.Errorf("bad second entry: %+v", history[1].Record)
	}
}

// Two endorsers execute the same proposal at different wall-clock instants: the resulting write sets must be
// identical, otherwise the gateway rejects the endorsements ("ProposalResponsePayloads do not match").
func TestEndorsersProduceIdenticalWriteSets(t *testing.T) {
	s := &SmartContract{}
	endorserA, endorserB := newFakeStub(), newFakeStub()

	if err := s.InsertDiagnostic(as(endorserA, "Org1MSP"), "r1", "p", "d", "dx", "o", "red", "ami", "loc", "h"); err != nil {
		t.Fatal(err)
	}
	time.Sleep(1100 * time.Millisecond) // the second endorser runs in a later wall-clock second
	if err := s.InsertDiagnostic(as(endorserB, "Org1MSP"), "r1", "p", "d", "dx", "o", "red", "ami", "loc", "h"); err != nil {
		t.Fatal(err)
	}
	if string(endorserA.state["r1"]) != string(endorserB.state["r1"]) {
		t.Errorf("insert write sets differ:\nA: %s\nB: %s", endorserA.state["r1"], endorserB.state["r1"])
	}

	if err := s.UpdateDiagnostic(as(endorserA, "Org2MSP"), "r1", "UNDER_REVIEW", "x", "", "", "", "", ""); err != nil {
		t.Fatal(err)
	}
	time.Sleep(1100 * time.Millisecond)
	if err := s.UpdateDiagnostic(as(endorserB, "Org2MSP"), "r1", "UNDER_REVIEW", "x", "", "", "", "", ""); err != nil {
		t.Fatal(err)
	}
	if string(endorserA.state["r1"]) != string(endorserB.state["r1"]) {
		t.Errorf("update write sets differ:\nA: %s\nB: %s", endorserA.state["r1"], endorserB.state["r1"])
	}
}
