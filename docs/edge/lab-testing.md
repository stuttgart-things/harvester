# Edge cluster -- lab testing: the device path and the apps

On a lab VM with the `edge-lab` layer (ESP mock, players' route). `export
KUBECONFIG=~/.kube/<node>`. The browser needs the edge root
(`clusters/<cluster>/edge-root-ca.crt`) as a trusted CA, otherwise it warns.

**The emulated ESP** (`lab/esp-mock`, deployment `piezo-a`) does what a device
does: at start an init container (`enrol`, lego) gets a certificate from
OpenBao via ACME HTTP-01 for `piezo-a.<EDGE_DOMAIN>` (role `devices`, the
challenge reaches the pod through an HTTPRoute on the `http` listener and a
Service with `publishNotReadyAddresses`), then the board (`piezo`,
zaehlwerk-piezo, `PIEZO_JOIN=true`) waits for a match started on the zaehlwerk
page, joins it and scores it to the end over HTTPS, a rally every 3 s
(including some ambiguous, resent and taken-back events), trusting only the
edge root; then it waits for the next match.

1. **Does the board play?** Start a match on `https://zaehlwerk.<EDGE_DOMAIN>`
   (two players and a scorer from schmetterpause), then:

   ```bash
   kubectl -n esp-mock logs -f deploy/piezo-a -c piezo     # "waiting for one to be started on the page" -> "joined" -> "rally" every 3 s -> "match over"
   kubectl -n zaehlwerk logs -f deploy/zaehlwerk            # "event ingested ... source: piezo-a, outcome: applied"
   ```

2. **Enrol again** (the device reboots):

   ```bash
   kubectl -n esp-mock rollout restart deploy/piezo-a
   kubectl -n esp-mock logs -f deploy/piezo-a -c enrol      # Trying to solve HTTP-01 -> validated -> Server responded with a certificate
   ```

3. **The device certificate** (the image has no shell, so a debug container
   reads the pod's filesystem):

   ```bash
   P=$(kubectl -n esp-mock get pod -l app.kubernetes.io/name=piezo-a -o name)
   kubectl -n esp-mock debug $P --image=alpine/openssl --target=piezo --profile=general -it -- sh -c \
     'openssl x509 -in $(ls /proc/1/root/certs/certificates/*.crt | grep -v issuer) -noout -subject -issuer -dates -ext extendedKeyUsage'
   ```

   Expect `CN=piezo-a.<EDGE_DOMAIN>`, issuer `stuttgart-things edge intermediate
   CA (openbao)`, 90 days. Note: the extended key usage is only `TLS Web Server
   Authentication`, although role `devices` sets `client_flag` -- for mutual TLS
   from the device this still has to be solved (OpenBao's ACME issuance).

4. **A name outside the allowed domain is refused:**

   ```bash
   D=<EDGE_DOMAIN>
   kubectl -n esp-mock run lego-neg --rm -i --restart=Never --image=goacme/lego:v4.35.2 --overrides='{"spec":{"volumes":[{"name":"ca","configMap":{"name":"edge-root-ca"}}],"containers":[{"name":"l","image":"goacme/lego:v4.35.2","env":[{"name":"LEGO_CA_CERTIFICATES","value":"/ca/root.crt"}],"args":["--server=https://openbao.'$D'/v1/pki/acme/directory","--email=neg@esp-mock.invalid","--accept-tos","--domains=evil.example.com","--http","--path=/tmp/l","run"],"volumeMounts":[{"name":"ca","mountPath":"/ca"}]}]}}'
   ```

   Expect `rejectedIdentifier ... role (devices) will not issue certificate for name evil.example.com`.

**Mock or real boards.** Every board sends its own `source` with each event:
the mock is `piezo-a` (`PIEZO_SOURCE`), a real board the name its firmware
carries; the certificates differ too (`piezo-a.<EDGE_DOMAIN>` vs. the name the
board gets on its network). Watch who scores:

```bash
kubectl -n zaehlwerk logs -f deploy/zaehlwerk | grep -o '"source":"[^"]*"'
```

**Never both at once.** zaehlwerk has one running match and every board in
join mode scores into it -- mock and real board together count each rally
twice. While real boards are at the table, switch the mock off in
`clusters/<cluster>/cluster-vars.yaml` and merge:

```yaml
EDGE_ESP_MOCK_REPLICAS: "0"   # "1" = mock on (default when the key is missing)
```

For a quick test without a commit: `flux suspend ks esp-mock -n flux-system`
and `kubectl -n esp-mock scale deploy/piezo-a --replicas=0`; `flux resume ks
esp-mock -n flux-system` brings it back to the value in `cluster-vars`. On the
LattePanda there is no mock at all (no `edge-lab` layer).

**Who may enrol:** `acme_eab_policy = "not-required"` -- any client that
passes the challenge for a name under `acme_allowed_domains` gets a
certificate, so the network is the gate (on the box: whoever gets a name from
the router). Stricter, when needed: EAB per device
(`new-account-required`, a key from `bao write -f pki/acme/new-eab` flashed
once) and device names only from static leases.

**Watching the apps** (all `https://<name>.<EDGE_DOMAIN>`):

| UI | What you see |
|---|---|
| `zaehlwerk` | the live match the mock plays |
| `led-catcher` | the LED matrix: it reads the `tabletennis` stream, so the score shows up (log: `caught: 1:4`) |
| `wled-mock` | the emulated light. Two catchers drive it: `light-catcher` (stream `messages`, homerun2 messages -- send one via `demo-pitcher`) and the table's own `light-catcher-tabletennis` (stream `tabletennis`): point for side a **blue**, side b **red** (1 s), set won rainbow (4 s), match won fireworks (10 s), an undo nothing |
| `light-catcher-tabletennis` | the table's light-catcher (namespace `homerun2-tabletennis`, AppProfile `homerun2-light-catcher-tabletennis-sops`); on the box its `HOMERUN2_LIGHT_CATCHER_TABLETENNIS_WLED_ENDPOINT` points at the real strip |
| `demo-pitcher`, `config-viewer` | send test messages; the homerun2 configuration |
| `schmetterpause` | the players' app -- matches started on `zaehlwerk` with its players end up here. Admin: `timoboll` (`SP_BOOTSTRAP_ADMIN` from `cluster-apps.yaml`), an observer -- it counts at zaehlwerk and never appears in the ranking. Setup order (schmetterpause `docs/admin-and-observers.md`): join on the page with its own PIN and never play, merge/restart so the flag is granted, then `/admin` → **Beobachter** on its own row (also `schmetterpause.<EDGE_PLAY_DOMAIN>` on the players' Gateway) |
