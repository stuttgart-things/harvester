# matrix — the homerun2 LED matrix

A Raspberry Pi 3B+ driving a 64x64 HUB75 RGB matrix through an Adafruit HAT.
It runs [homerun2-led-catcher](https://github.com/stuttgart-things/homerun2-led-catcher)
natively under systemd, in `standalone` mode: there is no Redis, and the panel is
driven over HTTP (`/display`). The same port serves the **demo UI**, a simulator
of the panel with a Panel control form. Between displays the panel shows a
clock.

There is no Kubernetes on the Pi. Everything here is one Ansible play, a DNS
record on the DD-WRT and a certificate from the OpenBao PKI on `platform`.

| | |
|---|---|
| Demo UI and API | **https://matrix.sthings.lab** (Caddy on 443, 80 redirects) |
| Direct, plain HTTP | http://192.168.10.120:8080 |
| Health | https://matrix.sthings.lab/healthz, which reports the installed version and commit |
| Board | Raspberry Pi 3 Model B Plus Rev 1.3, Raspberry Pi OS Trixie (64-bit) |
| wlan0 | `192.168.10.120`, MAC `b8:27:eb:d9:33:db`, static lease, the address used everywhere |
| eth0 | `192.168.10.107`, MAC `b8:27:eb:8c:66:8e`, dynamic; when cabled, the default route |
| Login | `sthings`, password auth |
| Service | `led-catcher.service` (the catcher), `caddy.service` (TLS) |

```
browser ──https──► caddy :443 ──http──► led-catcher 127.0.0.1:8080 ──► panel
            (cert from OpenBao PKI)          │
                                             └─ also :8080 on the LAN, plain HTTP
```

## DNS and DHCP on the DD-WRT

The name is a `host-record` in dnsmasq (forward and PTR, no wildcard, see
[`docs/install.md`](../../docs/install.md#dnsmasq-dns-for-sthingslab)), and the
wlan0 address is pinned with a static lease so the record stays true.

Set on 2026-09-21:

| nvram | added |
|---|---|
| `dnsmasq_options` | `host-record=matrix.sthings.lab,192.168.10.120` |
| `static_leases` | `B8:27:EB:D9:33:DB=matrix=192.168.10.120=` (`static_leasenum` 5 → 6) |

DD-WRT renders them into `/tmp/dnsmasq.conf` as
`host-record=matrix.sthings.lab,192.168.10.120` and
`dhcp-host=B8:27:EB:D9:33:DB,matrix,192.168.10.120,infinite`.

By hand in the web UI: *Services → Services → Dnsmasq → Additional Options*
for the record, and *Services → Services → DHCP Server → Static Leases* for the
lease. Over SSH, as it was done (idempotent: it adds nothing that is already
there):

```bash
ssh root@192.168.10.1 '
REC="host-record=matrix.sthings.lab,192.168.10.120"
LEASE="B8:27:EB:D9:33:DB=matrix=192.168.10.120="
opts="$(nvram get dnsmasq_options)"
case "$opts" in *"$REC"*) ;; *) nvram set dnsmasq_options="$opts
$REC";; esac
leases="$(nvram get static_leases)"
case "$leases" in *"B8:27:EB:D9:33:DB"*) ;; *)
  nvram set static_leases="${leases% } $LEASE"
  nvram set static_leasenum=$(( $(nvram get static_leasenum) + 1 ));; esac
nvram commit
stopservice dnsmasq && startservice dnsmasq'
```

Take a copy of both values first (`nvram get dnsmasq_options`, `nvram get
static_leases`). `nvram set` replaces a value whole, so a typo in the shell
quoting loses every other record. The stop/start is the second of the reload
commands Clusterbook tries (`internal/ddwrt.go`); `restart_dnsmasq` does not
exist on this build (r62374).

Check against the router itself, since a client's resolver may still cache the
earlier NXDOMAIN:

```bash
dig +short @192.168.10.1 matrix.sthings.lab        # 192.168.10.120
dig +short @192.168.10.1 -x 192.168.10.120         # matrix.sthings.lab.
```

`host-record` rather than `address=/…/`: the latter is a wildcard that also
answers for every name under `matrix.sthings.lab`, and has no PTR.

## The certificate

Issued by the OpenBao PKI on `platform` (`https://openbao.platform.sthings.lab`),
mount `pki`, role `sthings-lab`: subdomains of `sthings.lab`, IP SANs allowed,
at most a year. The play asks for 90 days (`led_tls_ttl`), and re-issues when
fewer than 30 are left (`led_tls_renew_days`), when the file is missing, or when
it names another host. **Renewing is re-running the play.** A run in the last 30
days before expiry issues a new certificate; any other run leaves it alone.

| | |
|---|---|
| Subject | `CN=matrix.sthings.lab` |
| SAN | `DNS:matrix.sthings.lab`, `IP:192.168.10.120` |
| Issuer | `C=DE, O=sva, CN=sthings.lab` |
| On the Pi | `/etc/caddy/tls/matrix.sthings.lab.crt` (with the issuing CA), `.key` (`0640 root:caddy`) |
| First issued | 2026-09-21, valid until 2026-12-20 |

The token is only needed when a certificate has to be issued. It is read on the
controller (`VAULT_TOKEN`) and only ever passed as a `no_log` task argument; the
Pi never stores it. A token with only the `pki-issue` policy is enough, and a
short-lived one is better than the root token:

```bash
export VAULT_ADDR=https://openbao.platform.sthings.lab
# from a token that may create tokens: 1 h, pki-issue only, no default policy
VAULT_TOKEN=$(curl -s -X POST -H "X-Vault-Token: $(cat ~/.vaulttoken)" \
  -d '{"policies":["pki-issue"],"ttl":"1h","display_name":"matrix-tls","no_default_policy":true}' \
  $VAULT_ADDR/v1/auth/token/create | jq -r .auth.client_token)
```

Browsers need the `sthings.lab` CA to trust the certificate. Images built from
`packer/` have it already. On a Mac, import it once into the keychain:

```bash
curl -sk https://openbao.platform.sthings.lab/v1/pki/ca/pem -o sthings-lab-ca.pem
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain sthings-lab-ca.pem
```

## Deploy: the play, through Dagger

[`sthings.container.homerun2_led_catcher_pi`](https://github.com/stuttgart-things/ansible/blob/main/collections/container/homerun2_led_catcher_pi.yaml)
does the whole install: boot config, the matrix library, the catcher in a venv,
the unit, and with `led_tls_hostname` the certificate and Caddy. A second run
changes nothing. The
[`ansible` module](https://github.com/stuttgart-things/dagger/tree/main/ansible) of
`stuttgart-things/dagger` runs it in a container, so no local Ansible is needed.
Run from this directory:

```bash
cd hosts/matrix

# credentials only in the environment; the module passes them as Dagger secrets
export SSH_USER=sthings SSH_PASSWORD='…'
umask 077
printf 'LED_API_TOKEN=%s\nVAULT_TOKEN=%s\n' "$LED_API_TOKEN" "$VAULT_TOKEN" > ansible.env

dagger -m github.com/stuttgart-things/dagger/ansible call execute \
  --src . \
  --requirements requirements.yml \
  --inventory inventory.ini \
  --playbooks sthings.container.homerun2_led_catcher_pi \
  --ssh-user env:SSH_USER \
  --ssh-password env:SSH_PASSWORD \
  --env-secrets file:ansible.env \
  --parameters "ansible_become_password='{{ lookup(\"env\", \"ANSIBLE_PASSWORD\") }}' \
led_api_token='{{ lookup(\"env\", \"LED_API_TOKEN\") }}' \
led_catcher_version=v0.12.0 \
led_tls_hostname=matrix.sthings.lab led_tls_ip_sans=192.168.10.120 \
led_idle=clock \
run_id=$(date +%s%N)" \
  --progress plain

rm -f ansible.env
```

| Parameter | |
|---|---|
| `led_catcher_version` | the homerun2-led-catcher release to check out; `/healthz` reports it |
| `led_tls_hostname`, `led_tls_ip_sans` | the certificate's names; without `led_tls_hostname` no certificate and no Caddy |
| `led_idle=clock` | the clock between displays, set in the unit, so it survives restarts (`led_idle_color`: a colour name or `r,g,b`) |
| `led_api_token` | the bearer token for `POST /display`, written to `/etc/default/led-catcher` (`0600`) |
| `run_id` | **must change on every call**. Dagger caches the `ansible-playbook` step, and without it a second call replays the first result and never reaches the Pi |

`VAULT_TOKEN` can be left out of `ansible.env` while the certificate is valid.
The play then reports `certificate ok before this run` and changes nothing.

## Operate

```bash
curl -s https://matrix.sthings.lab/healthz

# put something on the panel (the token from /etc/default/led-catcher)
curl -s -X POST https://matrix.sthings.lab/display -H "Authorization: Bearer $LED_API_TOKEN" \
  -H 'Content-Type: application/json' -d '{"kind":"text","text":"HELLO","color":"success"}'

# the clock: switch it or its colour at runtime (not persisted; the unit's LED_IDLE wins after a restart)
curl -s -X PUT https://matrix.sthings.lab/display/idle -H "Authorization: Bearer $LED_API_TOKEN" \
  -H 'Content-Type: application/json' -d '{"mode":"clock","color":[255,140,0]}'
```

The demo UI's **Panel control** does the same with the token typed in.

```bash
journalctl -u led-catcher -f     # on the Pi
journalctl -u caddy -f
```

## Known state

- **Under-voltage.** `vcgencmd get_throttled` reported `0x50005` (2026-09-21):
  under-voltage now, throttled now, both have happened before. The ARM clock
  stays at 600 MHz. Needs a 5.1 V/2.5 A supply with a short, thick cable, and
  the panel powered through the HAT rather than from the Pi.
- **Load.** The matrix library's refresh thread keeps core 3 (reserved with
  `isolcpus=3`) at ~75–80 %, lit or dark: that is by design. The catcher itself
  uses 2–10 %, 72 MB RSS.
- **After a crash** `Restart=always` brings the service back in ~15 s: 5 s
  `RestartSec` plus ~6 s of Python start-up on this board.
- Hardware test results: homerun2-led-catcher
  [#96](https://github.com/stuttgart-things/homerun2-led-catcher/issues/96),
  [#76](https://github.com/stuttgart-things/homerun2-led-catcher/issues/76),
  [#77](https://github.com/stuttgart-things/homerun2-led-catcher/issues/77),
  [#78](https://github.com/stuttgart-things/homerun2-led-catcher/issues/78).
