# 2026-05-22 — Prometheus Crash-Loop nach Host-Edit an alert-rules.yml

**Symptom:** Fast alle Grafana-Dashboards (Multi-Host-Overview etc.) zeigen „No data". Prometheus-Container im Restart-Loop, `/api/v1/*` antwortet nicht.

**Trigger:** Manueller Edit von `alert-rules.yml` direkt auf cachyos (vermutlich Threshold-Tuning per `vim`). Repo und Host liefen seit dem Edit out-of-sync.

## Soll → Ist → Lernpunkt

### Phase 1 — Root-Cause-Investigation

**Soll:** Eindeutige Fehlerursache identifizieren, bevor irgendwas angefasst wird.

**Ist:**
1. `docker ps -a` auf cachyos → `prometheus  Restarting (2) 58 seconds ago`. Smoking Gun.
2. `docker logs prometheus --tail 80` →
   ```
   /etc/prometheus/alert-rules.yml: 132:15: group "host-health", rule 13, "DiskReadSpike":
     could not parse expression: 1:43: parse error: unexpected character inside braces: '.'
   ```
3. Repo-Zeile 132 sah valide aus: `expr: rate(...{host="vps", device=~"sd.*"}[10m]) * 60 > 500`.
4. `promtool check rules` auf Repo-File **isoliert** → SUCCESS. Hypothese „Repo ist kaputt" widerlegt.
5. `sha256sum` Host vs. Repo:
   - Repo: `3554963f…`
   - Host: `77b50a49…` ← divergent.
6. `diff -u` zeigt **exakt eine** Zeile Unterschied (Zeile 132):
   ```diff
   - expr: rate(node_disk_reads_completed_total{host="vps", device=~"sd.*"}[10m]) * 60 > 500
   + expr: rate(node_disk_reads_completed_total{host=.vps., device=~.sd.*.}[10m]) * 60 > 2000
   ```
   Anführungszeichen `"` wurden zu `.` ersetzt, Threshold wurde `500 → 2000` getunt.

**Lernpunkt:** Erst Container-State + Logs → dann Hypothesen, nicht umgekehrt. `cat -A` auf das Host-File hätte das Problem in 5 Sekunden gezeigt, wenn man es direkt geöffnet hätte — aber das setzt voraus, dass man weiß, dass Host und Repo divergieren.

### Phase 2/3 — Hypothese & Test

**Soll:** Hypothese minimal testen.

**Ist:** Vier `promtool check rules` Test-Cases parallel auf cachyos (original / equality-match / escaped dot / block-scalar). **Alle SUCCESS.** Das deployte Host-File **FAILED**. Damit war klar: nur das deployte File ist kaputt, nicht das Pattern.

**Lernpunkt:** `promtool check rules` ist autoritativ und billig — vor jedem Prometheus-Restart laufen lassen, wenn Rules angefasst wurden.

### Phase 4 — Implementation

**Soll:** Host-File reparieren, Prometheus wieder hochbringen, verifizieren.

**Ist:**
1. Host-Backup: `alert-rules.yml.bak-20260522-090352`.
2. Repo-File (mit korrekten Quotes) nach `cachyos:/home/alex/monitoring/prometheus/alert-rules.yml` gescpt. **Hinweis:** parallel hatte eine andere Session bereits `13c0a0a fix(alerting): cadvisor Healthcheck + DiskReadSpike threshold 2000 IOPS` auf `origin/main` gepusht, der den Threshold `500 → 2000` ebenfalls im Repo gefixt + die Description verbessert hatte ("Systemd-Journal-Writes schlagen hier NICHT an"). Mein lokaler Threshold-Commit war damit redundant und wurde via `git reset --soft origin/main` verworfen — nur dieses Journal bleibt als neuer Commit.
3. `promtool check rules` auf dem deployten File → **SUCCESS: 19 rules found**.
4. `docker restart prometheus` → `Up`, Logs zeigen `Server is ready to receive web requests`.
5. `/-/ready` HTTP 200. `/api/v1/rules` liefert `host-health`-Gruppe sauber.

**Targets nach Restart:**
- `node_exporter`: 2/2 up
- `prometheus`: 1/1 up
- `traefik`: 1/1 up
- `cadvisor`: 0/1 **down** (VPS `100.92.62.9:8180`) — separates Problem, nicht durch diesen Fix verursacht. Loose End.

**Lernpunkt (der wichtige):**

> **Host-Edits an provisionierten Configs sind toxisch.** Repo ist Source of Truth.
> Tuning gehört ins Repo + redeploy, nicht in `vim` auf cachyos.

Das `"` → `.` deutet auf einen Editor- oder `sed`-Unfall hin. Hätte das File über den Repo-Workflow geändert, wäre der Bug entweder beim `git diff` aufgefallen oder beim CI-`promtool`-Check. Beides existiert aktuell nicht — siehe Folgearbeit.

## Folgearbeit

**Erledigt am 2026-05-22 (Folge-Session):**

- [x] Pre-Commit-Hook für `configs/**` → [.pre-commit-config.yaml](../.pre-commit-config.yaml), ruft `make validate`.
- [x] GitHub Actions CI: promtool + yamllint + `docker compose config` bei jedem PR → [.github/workflows/validate.yml](../.github/workflows/validate.yml).
- [x] `make deploy-monitoring` → scp + `curl -X POST /-/reload` (Prometheus hat `--web.enable-lifecycle` an, kein Container-Restart mehr nötig). Siehe [Makefile](../Makefile).
- [x] `make drift` → `sha256sum` deploy ↔ Repo, markiert Mismatches sofort.
- [x] cadvisor auf VPS: lief auf `127.0.0.1:8180` (Bridge-Mode) statt Tailnet-IP. Repo enthält jetzt [configs/monitoring/vps-cadvisor/docker-compose.yml](../configs/monitoring/vps-cadvisor/docker-compose.yml) mit `network_mode: host` + `--port=8180` (analog `node_exporter`), Image gepinnt auf `v0.49.1`. Target: `up=1 down=0`.

**Noch offen:**

- [ ] Drift-Check als Cron auf cachyos: `make drift` per `systemd.timer` → ntfy bei Mismatch (proaktiv statt manuell).
- [ ] [SETUP.md](../docs/SETUP.md) ergänzen um Hinweis, dass Tuning ein Repo-Workflow ist (`make deploy-monitoring`), kein Host-Workflow.
