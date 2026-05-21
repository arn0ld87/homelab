# xenrox/ntfy-alertmanager — Bridge-Config (scfg-Format).
#
# Rendering:
#   envsubst < config.scfg.tpl > config.scfg
#
# Erwartete ENV-Variable (aus ../alertmanager/.secrets.env, gitignored):
#   NTFY_TOPIC=${NTFY_TOPIC}
# Der echte Topic-Wert wird NIE ins Repo committed — er ist bei
# ntfy.sh ohne explizite ACLs effektiv ein Shared Secret.
#
# Doku: https://codeberg.org/xenrox/ntfy-alertmanager

# Bridge bindet ausschließlich auf Loopback, weil der Container im
# `network_mode: host` läuft und keine eigene Authentifizierung hat.
# Externe Erreichbarkeit auf einem öffentlichen VPS-Interface wäre ein
# offenes Webhook-Relay nach ntfy.sh.
http-address 127.0.0.1:9095
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
