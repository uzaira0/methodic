# TLS Certificates

Place your institutional TLS certificates here:

- `chronicle-screentime-app.research.bcm.edu.crt` - Full certificate chain (cert + intermediate CA)
- `chronicle-screentime-app.research.bcm.edu.key` - Private key (PEM format)

**Important:** The `.crt` file must contain the full chain: server cert first, then intermediate CA(s). If IT provides separate files, concatenate them:
```bash
cat server.crt intermediate.crt > chronicle-screentime-app.research.bcm.edu.crt
```

## Deployment Checklist

Once certs are placed here:

1. **Verify cert/key match:**
   ```bash
   openssl x509 -noout -modulus -in chronicle-screentime-app.research.bcm.edu.crt | openssl md5
   openssl rsa -noout -modulus -in chronicle-screentime-app.research.bcm.edu.key | openssl md5
   # Both MD5 hashes must match
   ```

2. **Verify cert chain is complete:**
   ```bash
   openssl verify -CAfile /etc/pki/tls/certs/ca-bundle.crt chronicle-screentime-app.research.bcm.edu.crt
   # Should print: chronicle-screentime-app.research.bcm.edu.crt: OK
   ```

3. **Check cert expiry and SAN:**
   ```bash
   openssl x509 -noout -dates -subject -ext subjectAltName -in chronicle-screentime-app.research.bcm.edu.crt
   ```

4. **Install Traefik configs (requires root/sudo):**
   ```bash
   # Copy TLS dynamic config
   sudo cp ../traefik-tls.yml /etc/dokploy/traefik/dynamic/chronicle-tls.yml

   # Copy certs to Traefik cert directory
   sudo mkdir -p /etc/traefik/certs
   sudo cp chronicle-screentime-app.research.bcm.edu.crt /etc/traefik/certs/
   sudo cp chronicle-screentime-app.research.bcm.edu.key /etc/traefik/certs/
   sudo chmod 600 /etc/traefik/certs/*.key

   # Optionally replace Traefik static config (disables ACME, enables file provider)
   sudo cp ../traefik.yml /etc/dokploy/traefik/traefik.yml
   ```

5. **Switch entrypoint to HTTPS** in `.env`:
   ```
   TRAEFIK_ENTRYPOINT=websecure
   ```

6. **Restart services:**
   ```bash
   cd /opt/chronicle/docker
   docker compose -p chronicle -f docker-compose.traefik.yml up -d
   ```

7. **Verify TLS is working:**
   ```bash
   curl -vI https://chronicle-screentime-app.research.bcm.edu/chronicle
   # Check: TLS 1.2+, correct cert, 200 OK
   ```

## Certificate Renewal

When IT provides renewed certs, replace the files above and restart Traefik:
```bash
# Replace cert files in /etc/traefik/certs/
# Traefik's file provider (watch: true) will auto-reload within seconds
# If not, restart Traefik: docker restart dokploy-traefik
```
