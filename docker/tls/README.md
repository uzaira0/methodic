# TLS Certificates

Place your institutional TLS certificates here:

- `chronicle-screentime-app.research.bcm.edu.crt` - Full certificate chain (cert + intermediate CA)
- `chronicle-screentime-app.research.bcm.edu.key` - Private key (PEM format)

These are mounted into Traefik via docker-compose and loaded via dynamic config.

## Testing

```bash
# Verify cert matches key
openssl x509 -noout -modulus -in chronicle-screentime-app.research.bcm.edu.crt | openssl md5
openssl rsa -noout -modulus -in chronicle-screentime-app.research.bcm.edu.key | openssl md5
# Both MD5 hashes should match
```
