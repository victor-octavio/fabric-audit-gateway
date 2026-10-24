package fabric

import (
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

// OrgConfig describes how the gateway connects to Fabric on behalf of one organization.
type OrgConfig struct {
	Name          string `yaml:"name"`
	MspID         string `yaml:"mspID"`
	CertPath      string `yaml:"certPath"`
	KeyPath       string `yaml:"keyPath"`
	TLSCertPath   string `yaml:"tlsCertPath"`
	PeerEndpoint  string `yaml:"peerEndpoint"`
	GatewayPeer   string `yaml:"gatewayPeer"`
	ChannelName   string `yaml:"channelName"`
	ChaincodeName string `yaml:"chaincodeName"`
}

type Config struct {
	Organizations []OrgConfig `yaml:"organizations"`
}

// LoadMultiOrg reads the organizations file pointed to by ORGS_CONFIG_PATH.
// Without it, a single organization is built from environment variables (Microfab dev mode).
func LoadMultiOrg() (Config, error) {
	path := os.Getenv("ORGS_CONFIG_PATH")
	if path == "" {
		return Config{Organizations: []OrgConfig{loadSingleOrgFromEnv()}}, nil
	}

	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, fmt.Errorf("failed to read organizations file: %w", err)
	}

	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return Config{}, fmt.Errorf("failed to parse organizations file: %w", err)
	}
	if len(cfg.Organizations) == 0 {
		return Config{}, fmt.Errorf("organizations file %s has no organizations", path)
	}
	return cfg, nil
}

func loadSingleOrgFromEnv() OrgConfig {
	return OrgConfig{
		Name:          getEnv("ORG_NAME", "emergency"),
		MspID:         getEnv("MSP_ID", "Org1MSP"),
		CertPath:      getEnv("CERT_PATH", "../network/wallet/org1admin/msp/signcerts/cert.pem"),
		KeyPath:       getEnv("KEY_PATH", "../network/wallet/org1admin/msp/keystore/key.pem"),
		TLSCertPath:   getEnv("TLS_CERT_PATH", ""),
		PeerEndpoint:  getEnv("PEER_ENDPOINT", "localhost:8080"),
		GatewayPeer:   getEnv("GATEWAY_PEER", "org1peer-api.127-0-0-1.nip.io:8080"),
		ChannelName:   getEnv("CHANNEL_NAME", "mychannel"),
		ChaincodeName: getEnv("CHAINCODE_NAME", "diagnostic-log"),
	}
}

func getEnv(key, fallback string) string {
	if val := os.Getenv(key); val != "" {
		return val
	}
	return fallback
}
