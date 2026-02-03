# OpenBao with SoftHSM2

Custom Docker image for OpenBao with SoftHSM2 support for testing and development.

## Overview

This image extends the official `openbao/openbao-hsm-ubi` image with SoftHSM2 library pre-installed, making it easy to test HSM (Hardware Security Module) functionality without needing physical HSM hardware.

## Features

- ✅ Based on official OpenBao HSM UBI image
- ✅ Pre-installed SoftHSM2 library
- ✅ Includes SoftHSM2 utilities (`softhsm2-util`, `softhsm2-dump`)
- ✅ Ready for PKCS#11 seal configuration
- ✅ Supports auto-unseal with HSM
- ✅ Bundled external secrets engine plugins (aws, gcp, azure)

## Quick Start

### Using Docker

```bash
# Pull the image
docker pull ghcr.io/itshare4u/openbao-hsm:latest

# Run with default settings
docker run -d --name openbao-hsm \
  -p 8200:8200 \
  ghcr.io/itshare4u/openbao-hsm:latest
```

### Using Docker Compose

```yaml
version: '3.8'

services:
  openbao:
    image: ghcr.io/itshare4u/openbao-hsm:latest
    container_name: openbao-hsm
    ports:
      - "8200:8200"
      - "8201:8201"
    environment:
      - BAO_SEAL_TYPE=pkcs11
      - BAO_HSM_LIB=/usr/local/lib/softhsm/libsofthsm2.so
      - BAO_HSM_TOKEN_LABEL=OpenBao
      - BAO_HSM_PIN=1234
      - BAO_HSM_KEY_LABEL=bao-unseal-key
      - BAO_HSM_HMAC_KEY_LABEL=bao-hmac-key
      - BAO_HSM_GENERATE_KEY=true
    volumes:
      - ./config:/openbao/config
      - ./data:/openbao/file
      - ./logs:/openbao/logs
    cap_add:
      - IPC_LOCK
    command: server -config=/openbao/config/openbao.hcl
```

## Initialize SoftHSM Token

Before starting OpenBao, initialize the SoftHSM token:

```bash
# Initialize token
docker exec openbao-hsm softhsm2-util --init-token --slot 0 --label "OpenBao" --so-pin 1234 --pin 1234

# Verify token
docker exec openbao-hsm softhsm2-util --show-slots
```

If `BAO_HSM_GENERATE_KEY=true`, the entrypoint will do this automatically.

## OpenBao Configuration

Create `openbao.hcl`:

```hcl
storage "raft" {
  path = "/openbao/file"
  node_id = "node1"
}

listener "tcp" {
  address = "0.0.0.0:8200"
  tls_disable = true
}

plugin_directory = "/usr/local/lib/openbao/plugins"

seal "pkcs11" {
  lib = "/usr/local/lib/softhsm/libsofthsm2.so"
  token_label = "OpenBao"
  pin = "1234"
  key_label = "bao-unseal-key"
  hmac_key_label = "bao-hmac-key"
  rsa_oaep_hash = "sha1"
  generate_key = "true"
  mechanism = "CKM_RSA_PKCS_KEY_PAIR_GEN"
}

disable_mlock = true
api_addr = "http://127.0.0.1:8200"
cluster_addr = "http://127.0.0.1:8201"
ui = true
```

## Initialize OpenBao

```bash
# Initialize with HSM
docker exec -it openbao-hsm bao operator init

# Unseal (auto-unseal should work with HSM)
docker exec openbao-hsm bao operator unseal
```

## Plugin Registration (aws/gcp/azure)

The image bundles external secret engine plugins. Register them once:

```bash
# aws
docker exec openbao-hsm sh -lc 'sha256sum /usr/local/lib/openbao/plugins/vault-plugin-secrets-aws'
docker exec openbao-hsm sh -lc 'bao plugin register -sha256=<SHA256> secret aws'
docker exec openbao-hsm sh -lc 'bao secrets enable -path=aws aws'
```

Repeat for:
- `vault-plugin-secrets-gcp` → name `gcp`
- `vault-plugin-secrets-azure` → name `azure`

If you set `BAO_ROOT_TOKEN` and keep `BAO_PLUGIN_AUTO_REGISTER=true`, the entrypoint will auto-register and enable these engines after OpenBao is healthy.

## SoftHSM Auto-Bootstrap

If `BAO_HSM_GENERATE_KEY=true`, the entrypoint will initialize the token (if missing) and generate `bao-unseal-key` + `bao-hmac-key` automatically.

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `BAO_SEAL_TYPE` | Seal type (pkcs11) | pkcs11 |
| `BAO_HSM_LIB` | Path to PKCS#11 library | /usr/local/lib/softhsm/libsofthsm2.so |
| `BAO_HSM_TOKEN_LABEL` | HSM token label | OpenBao |
| `BAO_HSM_PIN` | HSM user PIN | 1234 |
| `BAO_HSM_SO_PIN` | HSM SO PIN (token init) | same as `BAO_HSM_PIN` |
| `BAO_HSM_KEY_LABEL` | Key label for unseal | bao-unseal-key |
| `BAO_HSM_HMAC_KEY_LABEL` | HMAC key label | bao-hmac-key |
| `BAO_HSM_RSA_BITS` | RSA key size for unseal key | 3072 |
| `SOFTHSM2_CONF` | SoftHSM2 config path | /etc/softhsm/softhsm2.conf |
| `OPENBAO_PLUGIN_DIR` | Plugin directory | /usr/local/lib/openbao/plugins |
| `BAO_PLUGIN_AUTO_REGISTER` | Auto register plugins when `BAO_ROOT_TOKEN` is set | true |
| `BAO_ROOT_TOKEN` | Root token used for auto plugin registration | (empty) |

## Building from Source

```bash
# Clone repository
git clone https://github.com/itshare4u/openbao-hsm.git
cd openbao-hsm

# Build image
docker build -t openbao-hsm:latest .

# Or use Docker Compose
docker-compose build
```

## Repository Structure

```
.
├── Dockerfile              # Main Dockerfile
├── docker-compose.yml      # Docker Compose configuration
├── README.md               # This file
└── .github/
    └── workflows/
        └── docker-build.yml # GitHub Actions workflow
```

## License

This project follows the same license as OpenBao: [Mozilla Public License 2.0](https://github.com/openbao/openbao/blob/main/LICENSE)

## Credits

- [OpenBao](https://openbao.org/) - Open source secrets management
- [SoftHSM2](https://www.opendnssec.org/softhsm/) - Software implementation of HSM

## Support

For issues related to OpenBao itself, please visit [OpenBao GitHub](https://github.com/openbao/openbao).

For issues specific to this Docker image, please open an issue in this repository.
