# xenrox/ntfy-alertmanager — Bridge-Config (scfg-Format).
#
# Rendering:
#   envsubst < config.scfg.tpl > config.scfg
#
# Erwartete ENV-Variable (aus ../alertmanager/.secrets.env):
#   NTFY_TOPIC=ha-hpXCeqyiWiQaqUdbfarq8JIOxXLzzjTg
#
# Doku: https://codeberg.org/xenrox/ntfy-alertmanager

# Bridge hört auf 9095, weil 8080 = Weaviate, 9093/9094 = Alertmanager.
http-address :9095
log-level info
log-format text

# multi: gruppierte Alerts bleiben eine Notification.
alert-mode multi

# Label-basiertes Routing.
# Reihenfolge wichtig: erste passende Severity gewinnt Priority/Tags.
labels {
    order "severity"

    severity "critical" {
        priority 5
        tags "rotating_light,red_circle"
    }

    severity "warning" {
        priority 3
        tags "warning,yellow_circle"
    }
}

# Resolved-Alerts: existierende Notification updaten statt neue erzeugen.
resolved {
    update-notification true
    tags "white_check_mark"
    priority 2
}

ntfy {
    server https://ntfy.sh
    topic ${NTFY_TOPIC}
}
