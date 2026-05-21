# Alertmanager-Config-Template.
# Platzhalter werden beim Container-Start via envsubst aus .secrets.env
# ersetzt → /tmp/alertmanager.yml (chmod 600).

global:
  resolve_timeout: 5m

route:
  receiver: 'all-channels'
  group_by: ['alertname', 'host']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

receivers:
  - name: 'all-channels'
    webhook_configs:
      # ntfy via Bridge (alertmanager-ntfy) — formatiert Title/Tags/Priority
      # aus Labels. Direkter Push an ntfy.sh würde nur rohes JSON liefern.
      - url: 'http://127.0.0.1:9095/hook'
        send_resolved: true
        http_config:
          follow_redirects: true
    telegram_configs:
      - bot_token: '${TELEGRAM_BOT_TOKEN}'
        chat_id: ${TELEGRAM_CHAT_ID}
        parse_mode: 'HTML'
        send_resolved: true
        message: |
          <b>{{ .Status | toUpper }}</b> — {{ .CommonLabels.alertname }}
          {{ range .Alerts }}
          <b>Host:</b> {{ .Labels.host }}{{ if .Labels.instance }} ({{ .Labels.instance }}){{ end }}
          <b>Severity:</b> {{ .Labels.severity }}
          {{ .Annotations.summary }}
          {{ if .Annotations.description }}{{ .Annotations.description }}{{ end }}
          {{ end }}

inhibit_rules:
  - source_matchers: ['severity = critical']
    target_matchers: ['severity = warning']
    equal: ['alertname', 'host']
