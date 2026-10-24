package fabric

import (
	"fmt"
	"os"
	"sort"
	"time"

	"github.com/hyperledger/fabric-gateway/pkg/client"
	"github.com/hyperledger/fabric-gateway/pkg/identity"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
)

// MultiGateway holds one Fabric Gateway connection per organization, keyed by organization name.
type MultiGateway struct {
	gateways  map[string]*client.Gateway
	contracts map[string]*client.Contract
	conns     map[string]*grpc.ClientConn
}

func NewMultiGateway(cfg Config) (*MultiGateway, error) {
	mg := &MultiGateway{
		gateways:  make(map[string]*client.Gateway),
		contracts: make(map[string]*client.Contract),
		conns:     make(map[string]*grpc.ClientConn),
	}

	for _, org := range cfg.Organizations {
		if _, dup := mg.contracts[org.Name]; dup {
			mg.Close()
			return nil, fmt.Errorf("duplicate organization name %q", org.Name)
		}
		if err := mg.connect(org); err != nil {
			mg.Close()
			return nil, fmt.Errorf("organization %q: %w", org.Name, err)
		}
	}
	return mg, nil
}

func (m *MultiGateway) connect(org OrgConfig) error {
	conn, err := newGrpcConnection(org)
	if err != nil {
		return fmt.Errorf("failed to connect via gRPC: %w", err)
	}

	id, err := newIdentity(org)
	if err != nil {
		conn.Close()
		return fmt.Errorf("failed to load identity: %w", err)
	}

	sign, err := newSigner(org)
	if err != nil {
		conn.Close()
		return fmt.Errorf("failed to load signer: %w", err)
	}

	gw, err := client.Connect(
		id,
		client.WithSign(sign),
		client.WithClientConnection(conn),
		client.WithEvaluateTimeout(5*time.Second),
		client.WithEndorseTimeout(15*time.Second),
		client.WithSubmitTimeout(5*time.Second),
		client.WithCommitStatusTimeout(60*time.Second),
	)
	if err != nil {
		conn.Close()
		return fmt.Errorf("failed to create gateway: %w", err)
	}

	m.conns[org.Name] = conn
	m.gateways[org.Name] = gw
	m.contracts[org.Name] = gw.GetNetwork(org.ChannelName).GetContract(org.ChaincodeName)
	return nil
}

// Contract returns the contract bound to the identity of the given organization.
func (m *MultiGateway) Contract(orgName string) (*client.Contract, error) {
	contract, ok := m.contracts[orgName]
	if !ok {
		return nil, fmt.Errorf("unknown organization %q", orgName)
	}
	return contract, nil
}

// OrgNames returns the configured organization names, sorted.
func (m *MultiGateway) OrgNames() []string {
	names := make([]string, 0, len(m.contracts))
	for name := range m.contracts {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

func (m *MultiGateway) Close() {
	for _, gw := range m.gateways {
		gw.Close()
	}
	for _, conn := range m.conns {
		conn.Close()
	}
}

func newGrpcConnection(org OrgConfig) (*grpc.ClientConn, error) {
	// Without a TLS CA (Microfab dev mode) fall back to plaintext, using the authority header
	// so the Microfab proxy routes the call to the right peer.
	if org.TLSCertPath == "" {
		return grpc.NewClient(
			org.PeerEndpoint,
			grpc.WithTransportCredentials(insecure.NewCredentials()),
			grpc.WithAuthority(org.GatewayPeer),
		)
	}

	creds, err := credentials.NewClientTLSFromFile(org.TLSCertPath, org.GatewayPeer)
	if err != nil {
		return nil, fmt.Errorf("failed to load TLS certificate: %w", err)
	}
	return grpc.NewClient(org.PeerEndpoint, grpc.WithTransportCredentials(creds))
}

func newIdentity(org OrgConfig) (*identity.X509Identity, error) {
	certPEM, err := os.ReadFile(org.CertPath)
	if err != nil {
		return nil, fmt.Errorf("failed to read certificate: %w", err)
	}

	cert, err := identity.CertificateFromPEM(certPEM)
	if err != nil {
		return nil, fmt.Errorf("failed to parse certificate: %w", err)
	}

	return identity.NewX509Identity(org.MspID, cert)
}

func newSigner(org OrgConfig) (identity.Sign, error) {
	keyPEM, err := os.ReadFile(org.KeyPath)
	if err != nil {
		return nil, fmt.Errorf("failed to read private key: %w", err)
	}

	privateKey, err := identity.PrivateKeyFromPEM(keyPEM)
	if err != nil {
		return nil, fmt.Errorf("failed to parse private key: %w", err)
	}

	return identity.NewPrivateKeySign(privateKey)
}
