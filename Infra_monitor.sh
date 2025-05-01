#!/usr/bin/env zsh
set -euo pipefail

# --- Redirect all output (stdout and stderr) to log file with timestamps ---
LOG_FILE="./infra_monitor.log"

exec > >(
  while IFS= read -r line; do
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $line"
  done | tee -a "$LOG_FILE"
) 2>&1

# --- Configuration ---
CONFIG_FILE="./infra_monitor.conf"
typeset -A THRESHOLDS=(
  CPU_CRIT 95
  CPU_WARN 80
  MEM_CRIT 90
  MEM_WARN 70
  DISK_CRIT 90
  DISK_WARN 80
)
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
PROMETHEUS_PUSHGATEWAY="http://localhost:9091"
INSTANCE_NAME=$(hostname)
typeset -A SERVICE_PORTS=(
  nginx 80
  postgres 5432
  redis 6379
)

# --- Initialization ---
load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
    echo "Configuration loaded from $CONFIG_FILE"
  else
    echo "Configuration file not found!"
    exit 1
  fi
}

# --- Helper Functions ---
send_alert() {
  local level=$1
  local message=$2
  echo "Sending alert: [$level] $message"
  curl -s -X POST \
    -H 'Content-Type: application/json' \
    -d "{\"chat_id\":\"$TELEGRAM_CHAT_ID\",\"text\":\"[$level] $message\"}" \
    "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" >/dev/null
}

push_metric() {
  local metric=$1
  local value=$2
  local labels=$3
  [[ -n "$labels" ]] && labels=",$labels"
  echo "Pushing metric: $metric $value $labels"
  curl -s -X POST "$PROMETHEUS_PUSHGATEWAY/metrics/job/infra_monitor/instance/$INSTANCE_NAME$labels" \
    --data-binary "$metric $value" >/dev/null
}

# --- Checks ---
check_cpu() {
  echo "Checking CPU usage..."
  local cpu_idle cpu_usage
  cpu_idle=$(iostat -c 2 | tail -n 1 | awk '{print $6}')
  cpu_usage=$(awk "BEGIN {print 100 - $cpu_idle}")

  push_metric "cpu_usage" "$cpu_usage" "type=percent"

  if (( $(echo "$cpu_usage >= ${THRESHOLDS[CPU_CRIT]}" | bc -l) )); then
    send_alert "CRITICAL" "CPU usage is at ${cpu_usage}%"
    return 2
  elif (( $(echo "$cpu_usage >= ${THRESHOLDS[CPU_WARN]}" | bc -l) )); then
    send_alert "WARNING" "CPU usage is at ${cpu_usage}%"
    return 1
  fi
}

check_memory() {
  echo "Checking memory usage..."
  local pages_free pages_active pages_inactive pages_speculative pages_wired pages_used mem_total mem_usage
  pages_free=$(vm_stat | awk '/Pages free/ {print $3}' | tr -d '.')
  pages_active=$(vm_stat | awk '/Pages active/ {print $3}' | tr -d '.')
  pages_inactive=$(vm_stat | awk '/Pages inactive/ {print $3}' | tr -d '.')
  pages_speculative=$(vm_stat | awk '/Pages speculative/ {print $3}' | tr -d '.')
  pages_wired=$(vm_stat | awk '/Pages wired down/ {print $4}' | tr -d '.')
  pages_used=$((pages_active + pages_inactive + pages_speculative + pages_wired))
  mem_total=$((pages_used + pages_free))
  mem_usage=$(awk "BEGIN {printf \"%.2f\", ($pages_used / $mem_total) * 100}")
  mem_usage=${mem_usage/,/.}  # Replace comma with dot if locale uses comma

  push_metric "memory_usage" "$mem_usage" "type=percent"

  if (( $(echo "$mem_usage >= ${THRESHOLDS[MEM_CRIT]}" | bc -l) )); then
    send_alert "CRITICAL" "Memory usage is at ${mem_usage}%"
    return 2
  elif (( $(echo "$mem_usage >= ${THRESHOLDS[MEM_WARN]}" | bc -l) )); then
    send_alert "WARNING" "Memory usage is at ${mem_usage}%"
    return 1
  fi
}

check_disk() {
  echo "Checking disk usage..."
  local disk_usage
  disk_usage=$(df / | tail -1 | awk '{print $5}' | tr -d '%')

  push_metric "disk_usage" "$disk_usage" "type=percent"

  if (( disk_usage >= THRESHOLDS[DISK_CRIT] )); then
    send_alert "CRITICAL" "Disk usage is at ${disk_usage}%"
    return 2
  elif (( disk_usage >= THRESHOLDS[DISK_WARN] )); then
    send_alert "WARNING" "Disk usage is at ${disk_usage}%"
    return 1
  fi
}

check_network() {
  echo "Checking network packet loss..."
  local loss
  loss=$(ping -c 3 8.8.8.8 | grep 'packet loss' | sed -E 's/.*, ([0-9]+(\.[0-9]+)?)% packet loss.*/\1/')
  loss=${loss:-100}

  push_metric "network_packet_loss" "$loss" "type=percent"

  if (( $(echo "$loss > 50" | bc -l) )); then
    send_alert "CRITICAL" "Network packet loss is at ${loss}%"
    return 2
  elif (( $(echo "$loss > 20" | bc -l) )); then
    send_alert "WARNING" "Network packet loss is at ${loss}%"
    return 1
  fi
}

check_services() {
  echo "Checking services status..."
  local service port service_status
  for service port in ${(kv)SERVICE_PORTS}; do
    if nc -z localhost $port; then
      service_status=1
    else
      service_status=0
      send_alert "CRITICAL" "Service $service is DOWN!"
    fi
    push_metric "service_status" "$service_status" "service=\"$service\",port=\"$port\""
  done
}

# --- Main Loop ---
main() {
  load_config
  trap "echo 'Script terminated'; exit 0" SIGINT SIGTERM

  while true; do
    check_cpu &
    check_memory &
    check_disk &
    check_network &
    check_services &
    wait
    sleep 60
  done
}

# --- Entry Point ---
if [[ "${(%):-%N}" == "$0" ]]; then
  main "$@"
fi
