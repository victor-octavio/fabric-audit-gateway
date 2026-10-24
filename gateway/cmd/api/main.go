package main

import (
	"log"

	"github.com/victor-octavio/telehealth-audit-api/gateway/internal/handlers"
	"github.com/victor-octavio/telehealth-audit-api/gateway/internal/repositories"
	"github.com/victor-octavio/telehealth-audit-api/gateway/internal/usecases"
	"github.com/victor-octavio/telehealth-audit-api/gateway/pkg/fabric"
)

func main() {
	cfg, err := fabric.LoadMultiOrg()
	if err != nil {
		log.Fatalf("Error loading organizations config: %v", err)
	}

	gateway, err := fabric.NewMultiGateway(cfg)
	if err != nil {
		log.Fatalf("Error starting multi-org hyperledger fabric connection: %v", err)
	}
	defer gateway.Close()

	repo := repositories.New(repositories.Options{Gateway: gateway})
	uc := usecases.New(usecases.Options{Repo: repo})
	h := handlers.New(handlers.Options{UC: uc, OrgNames: gateway.OrgNames()})

	log.Printf("Gateway ready for organizations: %v", gateway.OrgNames())
	if err := h.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}
