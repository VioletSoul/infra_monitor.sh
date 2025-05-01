#!/usr/bin/env zsh
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
set -euo pipefail

LOG_FILE="./infra_monitor.log"

exec > >(
  while IFS= read -r line; do
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $line"
  done | tee -a "$LOG_FILE"
) 2>&1

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

cpu_usage=""
mem_usage=""
disk_usage=""
network_loss=""
typeset -A service_statuses

disk_read_ops=0
disk_write_ops=0

net_bytes_in=0
net_bytes_out=0
net_packets_in=0
net_packets_out=0

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
    echo "Configuration loaded from $CONFIG_FILE"
  else
    echo "Configuration file not found!"
    exit 1
  fi
}

send_alert() {
  local level=$1
  local message=$2
  echo "Sending alert: [$level] $message"
  if [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
    curl -s -X POST \
      -H 'Content-Type: application/json' \
      -d "{\"chat_id\":\"$TELEGRAM_CHAT_ID\",\"text\":\"[$level] $message\"}" \
      "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" >/dev/null
  fi
}

check_cpu() {
  echo "Checking CPU usage..."
  local cpu_val
  cpu_val=$(top -l 2 -n 0 | grep "CPU usage" | tail -1 | awk '{print $3 + $5}' | sed 's/%//g')
  cpu_val=${cpu_val:-0}
  cpu_usage=$cpu_val

  if (( $(echo "$cpu_val >= ${THRESHOLDS[CPU_CRIT]}" | bc -l) )); then
    send_alert "CRITICAL" "CPU usage is at ${cpu_val}%"
  elif (( $(echo "$cpu_val >= ${THRESHOLDS[CPU_WARN]}" | bc -l) )); then
    send_alert "WARNING" "CPU usage is at ${cpu_val}%"
  fi
}

check_memory() {
  echo "Checking memory usage..."

  local page_size pages_active pages_inactive pages_wired pages_free pages_compressed pages_used pages_total
  local bytes_used bytes_total mem_val

  page_size=$(vm_stat | grep "page size of" | awk '{print $8}')
  page_size=${page_size:-4096}

  pages_active=$(vm_stat | awk '/Pages active:/ {print $3}' | tr -d '.')
  pages_inactive=$(vm_stat | awk '/Pages inactive:/ {print $3}' | tr -d '.')
  pages_wired=$(vm_stat | awk '/Pages wired down:/ {print $4}' | tr -d '.')
  pages_free=$(vm_stat | awk '/Pages free:/ {print $3}' | tr -d '.')
  pages_compressed=$(vm_stat | awk '/Pages occupied by compressor:/ {print $5}' | tr -d '.')

  for val in $pages_active $pages_inactive $pages_wired $pages_free $pages_compressed $page_size; do
    if [[ -z "$val" ]]; then
      echo "WARNING: vm_stat output incomplete, setting mem_usage=0"
      mem_usage=0
      return
    fi
  done

  pages_used=$((pages_active + pages_wired + pages_compressed))
  pages_total=$((pages_used + pages_inactive + pages_free))

  bytes_used=$((pages_used * page_size))
  bytes_total=$((pages_total * page_size))

  if (( bytes_total == 0 )); then
    mem_val=0
  else
    mem_val=$(awk "BEGIN {printf \"%.2f\", ($bytes_used / $bytes_total) * 100}")
  fi

  mem_val=$(echo "$mem_val" | tr ',' '.')

  mem_usage=$mem_val

  if (( $(echo "$mem_val >= ${THRESHOLDS[MEM_CRIT]}" | bc -l) )); then
    send_alert "CRITICAL" "Memory usage is at ${mem_val}%"
  elif (( $(echo "$mem_val >= ${THRESHOLDS[MEM_WARN]}" | bc -l) )); then
    send_alert "WARNING" "Memory usage is at ${mem_val}%"
  fi
}

check_disk() {
  echo "Checking disk usage..."
  local disk_val disk_num
  local disk_path="/"

  disk_val=$(df "$disk_path" | tail -1 | awk '{print $5}' | tr -d '%')

  if [[ -z "$disk_val" ]]; then
    disk_usage=0
    return
  fi

  disk_num=${disk_val%%.*}
  disk_usage=$disk_val

  if (( disk_num >= THRESHOLDS[DISK_CRIT] )); then
    send_alert "CRITICAL" "Disk usage on $disk_path is at ${disk_val}%"
  elif (( disk_num >= THRESHOLDS[DISK_WARN] )); then
    send_alert "WARNING" "Disk usage on $disk_path is at ${disk_val}%"
  fi
}

check_disk_io() {
  echo "Checking disk I/O..."

  local line
  line=$(iostat -d 1 2 | awk '
    $1 == "disk0" {line = $0}
    END {print line}
  ')

  if [[ -z "$line" ]]; then
    disk_read_ops=0
    disk_write_ops=0
    return
  fi

  disk_read_ops=$(echo "$line" | awk '{print $3}')
  disk_write_ops=$(echo "$line" | awk '{print $4}')

  if ! [[ "$disk_read_ops" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    disk_read_ops=0
  fi
  if ! [[ "$disk_write_ops" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    disk_write_ops=0
  fi
}

check_network() {
  echo "Checking network packet loss..."
  local loss_val

  loss_val=$(ping -c 3 8.8.8.8 | grep 'packet loss' | sed -E 's/.*, ([0-9]+(\.[0-9]+)?)% packet loss.*/\1/')

  if [[ -z "$loss_val" ]]; then
    network_loss=100
    return
  fi

  network_loss=$loss_val

  if (( $(echo "$loss_val > 50" | bc -l) )); then
    send_alert "CRITICAL" "Network packet loss is at ${loss_val}%"
  elif (( $(echo "$loss_val > 20" | bc -l) )); then
    send_alert "WARNING" "Network packet loss is at ${loss_val}%"
  fi
}

check_network_io() {
  echo "Checking network I/O..."

  local iface
  iface=$(route get default 2>/dev/null | awk '/interface: / {print $2}')
  if [[ -z "$iface" ]]; then
    echo "Cannot determine default network interface"
    net_bytes_in=0
    net_bytes_out=0
    net_packets_in=0
    net_packets_out=0
    return
  fi

  local in_bytes out_bytes in_pkts out_pkts
  in_bytes=$(netstat -ib | awk -v iface="$iface" '$1==iface {print $7; exit}')
  out_bytes=$(netstat -ib | awk -v iface="$iface" '$1==iface {print $10; exit}')
  in_pkts=$(netstat -ib | awk -v iface="$iface" '$1==iface {print $6; exit}')
  out_pkts=$(netstat -ib | awk -v iface="$iface" '$1==iface {print $9; exit}')

  net_bytes_in=${in_bytes:-0}
  net_bytes_out=${out_bytes:-0}
  net_packets_in=${in_pkts:-0}
  net_packets_out=${out_pkts:-0}
}

check_services() {
  echo "Checking services status..."
  local service port svc_status
  for service port in ${(kv)SERVICE_PORTS}; do
    if nc -z localhost $port; then
      svc_status=1
    else
      svc_status=0
      send_alert "CRITICAL" "Service $service is DOWN!"
    fi
    service_statuses[$service]=$svc_status
  done
}

push_all_metrics() {
  echo "Pushing all metrics to Pushgateway..."

  cpu_usage=${cpu_usage:-0}
  mem_usage=${mem_usage:-0}
  disk_usage=${disk_usage:-0}
  network_loss=${network_loss:-0}
  disk_read_ops=${disk_read_ops:-0}
  disk_write_ops=${disk_write_ops:-0}
  net_bytes_in=${net_bytes_in:-0}
  net_bytes_out=${net_bytes_out:-0}
  net_packets_in=${net_packets_in:-0}
  net_packets_out=${net_packets_out:-0}

  local payload
  payload="# TYPE cpu_usage gauge
cpu_usage{type=\"percent\",instance=\"$INSTANCE_NAME\"} $cpu_usage
# TYPE memory_usage gauge
memory_usage{type=\"percent\",instance=\"$INSTANCE_NAME\"} $mem_usage
# TYPE disk_usage gauge
disk_usage{type=\"percent\",instance=\"$INSTANCE_NAME\"} $disk_usage
# TYPE network_packet_loss gauge
network_packet_loss{type=\"percent\",instance=\"$INSTANCE_NAME\"} $network_loss
# TYPE disk_read_ops gauge
disk_read_ops{instance=\"$INSTANCE_NAME\"} $disk_read_ops
# TYPE disk_write_ops gauge
disk_write_ops{instance=\"$INSTANCE_NAME\"} $disk_write_ops
# TYPE net_bytes_in gauge
net_bytes_in{instance=\"$INSTANCE_NAME\"} $net_bytes_in
# TYPE net_bytes_out gauge
net_bytes_out{instance=\"$INSTANCE_NAME\"} $net_bytes_out
# TYPE net_packets_in gauge
net_packets_in{instance=\"$INSTANCE_NAME\"} $net_packets_in
# TYPE net_packets_out gauge
net_packets_out{instance=\"$INSTANCE_NAME\"} $net_packets_out"

  for service port in ${(kv)SERVICE_PORTS}; do
    local svc_status=${service_statuses[$service]:-0}
    payload+=$'\n'
    payload+="service_status{service=\"$service\",port=\"$port\",instance=\"$INSTANCE_NAME\"} $svc_status"
  done

  echo "Payload to push:"
  echo "$payload"

  curl -s -X POST --data-binary @- "$PROMETHEUS_PUSHGATEWAY/metrics/job/infra_monitor/instance/$INSTANCE_NAME" <<< "$payload"
}

main() {
  load_config
  trap "echo 'Script terminated'; exit 0" SIGINT SIGTERM

  while true; do
    check_cpu
    check_memory
    check_disk
    check_disk_io
    check_network
    check_network_io
    check_services

    push_all_metrics

    sleep 5
  done
}

if [[ "${(%):-%N}" == "$0" ]]; then
  main "$@"
fi
