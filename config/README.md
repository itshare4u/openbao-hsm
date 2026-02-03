# OpenBao Configuration

Copy `openbao.hcl.example` to `openbao.hcl` and customize as needed.

## Important

- Change the PIN in production!
- Use TLS certificates for production
- Back up the SoftHSM tokens directory
- If you see PKCS#11 OAEP errors, keep `rsa_oaep_hash = "sha1"` in `openbao.hcl` for SoftHSM compatibility
