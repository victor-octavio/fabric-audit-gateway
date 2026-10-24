package repositories

import (
	"errors"
	"testing"

	models "github.com/victor-octavio/telehealth-audit-api/gateway/internal/models/diagnosis"
)

func TestTranslateError(t *testing.T) {
	cases := []struct {
		msg  string
		want error
	}{
		{"permission denied: organization Org3MSP cannot perform this operation", models.ErrPermissionDenied},
		{"invalid status transition: OPEN -> CLOSED", models.ErrInvalidTransition},
		{"invalid severity \"purple\": must be red", models.ErrInvalidInput},
		{"diagnosis not found, { id: x }", models.ErrNotFound},
		{"diagnosis r1 already exists", models.ErrAlreadyExists},
	}
	for _, tc := range cases {
		err := translateError("ctx", errors.New(tc.msg))
		if !errors.Is(err, tc.want) {
			t.Errorf("%q: got %v, want %v", tc.msg, err, tc.want)
		}
	}
	if err := translateError("ctx", errors.New("timeout")); errors.Is(err, models.ErrNotFound) {
		t.Error("unrecognized error must not map to a domain error")
	}
}
