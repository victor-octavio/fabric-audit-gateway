package models

import "errors"

// Domain errors raised by the chaincode, used by the handlers to pick the HTTP status.
var (
	ErrPermissionDenied  = errors.New("permission denied")
	ErrInvalidTransition = errors.New("invalid status transition")
	ErrInvalidInput      = errors.New("invalid input")
	ErrNotFound          = errors.New("not found")
	ErrAlreadyExists     = errors.New("already exists")
)
