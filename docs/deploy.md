# Deploying the backend to Vultr

The API runs in Docker behind Caddy, which gets and renews the HTTPS certificate on its own. iOS only talks to HTTPS servers, so this is how the app reaches the backend.

```txt
iPhone ──HTTPS──▶ Caddy (ports 80, 443) ──▶ api (uvicorn, port 8000, 1 worker)
```

Time needed: about 20 minutes. You need a Vultr account, SSH access, and either a domain name or the `sslip.io` fallback in step 3.

## 1. Create the server

In Vultr, deploy a new Cloud Compute instance:

- **Image:** Ubuntu 24.04 LTS x64
- **Location:** New York (NJ) or Chicago, the closest regions to State College
- **Plan:** the smallest shared-CPU plan with at least 1 GB of RAM is enough
- **SSH key:** add your public key so you can log in without a password

Note the server's public IPv4 address.

## 2. Open the firewall

Create a Vultr firewall group that allows only these inbound ports, then attach it to the server:

| Port | Protocol | Why |
| --- | --- | --- |
| 22 | TCP | SSH |
| 80 | TCP | Certificate challenge and redirect to HTTPS |
| 443 | TCP | HTTPS |
| 443 | UDP | HTTP/3 (optional) |

Prefer the Vultr firewall over `ufw`: ports published by Docker bypass `ufw` rules.

## 3. Point a hostname at the server

**With a domain:** add a DNS `A` record, for example `api` → the server's IPv4. Check it from your laptop:

```bash
dig +short api.example.com
```

It must print the server IP before you start Caddy, or the certificate request fails.

**Without a domain:** use `sslip.io`, which resolves any hostname that contains an IP to that IP. For a server at `45.77.1.2`, use `45-77-1-2.sslip.io`. No DNS setup is needed, but many people share this domain, so Let's Encrypt can rate-limit it. A real domain is more reliable for the demo.

## 4. Install Docker

```bash
ssh root@<server-ip>
curl -fsSL https://get.docker.com | sh
docker compose version
```

## 5. Get the code

The repository is public, so no GitHub login is needed on the server.

```bash
git clone https://github.com/RamboHtoo/drive-save.git
cd drive-save
git switch backend
```

## 6. Configure

```bash
cp backend/.env.example backend/.env
openssl rand -hex 16   # copy this value into ADMIN_KEY
nano backend/.env
```

| Variable | Value |
| --- | --- |
| `API_DOMAIN` | The hostname from step 3, for example `api.example.com` |
| `ADMIN_KEY` | The random value you just generated |
| `DATABASE_URL` | The Tiger Data connection string (leave the placeholder until stage 2) |
| `CORS_ORIGINS` | `*` |

`backend/.env` holds secrets. It is git-ignored; never commit it or paste it into chat.

## 7. Start

```bash
cd backend
docker compose up -d --build
```

## 8. Check

```bash
docker compose ps                                  # api should say "healthy"
docker compose logs caddy | grep -i certificate    # look for "certificate obtained successfully"
curl https://api.example.com/health                # {"status":"ok","version":"0.1.0"}
```

Then open `https://api.example.com/health` on a phone **using cellular data, not Wi-Fi**, and `https://api.example.com/docs` in a browser.

## 9. Share the URL

Put the URL in the "Base URL" line of [`docs/api.md`](api.md) and send it to the iOS owner. The app no longer needs `NSAllowsLocalNetworking` once it uses this HTTPS URL.

## Updating

```bash
cd ~/drive-save && git pull
cd backend && docker compose up -d --build
```

Until Tiger Data is connected, data lives in memory: **every restart or redeploy deletes all users, crews and trips.** Re-run the demo setup afterwards.

## Useful commands

Run these from `drive-save/backend`.

| Command | What it does |
| --- | --- |
| `docker compose logs -f api` | Follow API logs |
| `docker compose logs -f caddy` | Follow Caddy logs (certificates, proxy errors) |
| `docker compose restart api` | Restart only the API |
| `docker compose down` | Stop everything (certificates are kept in the `caddy_data` volume) |

## Troubleshooting

| Symptom | Likely cause and fix |
| --- | --- |
| `Set API_DOMAIN in backend/.env` when starting | `backend/.env` is missing or `API_DOMAIN` is empty. Redo step 6 |
| Caddy logs show certificate errors | DNS doesn't point at the server yet, or port 80 is blocked. Check step 3 with `dig` and the firewall in step 2 |
| Certificate errors mentioning rate limits | Too many attempts for this hostname. Switch from `sslip.io` to a real domain, or wait |
| `502 Bad Gateway` | The API container is down. Run `docker compose logs api` |
| The iPhone can't connect | Use the `https://` hostname, not the raw IP. Test on cellular data to rule out venue Wi-Fi |
| Users and crews disappeared | Expected after a restart until Tiger Data is connected |

## Test the stack on your laptop

With Docker Desktop running, set `API_DOMAIN=localhost` in `backend/.env`, then:

```bash
cd backend
docker compose up -d --build
curl -k https://localhost/health
docker compose down -v
```

Caddy uses a self-signed certificate for `localhost`, so `-k` skips the certificate check.
