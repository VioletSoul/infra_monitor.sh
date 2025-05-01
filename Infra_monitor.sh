#!/usr/bin/env zsh

# ------------------------------------------
# Infrastructure Monitoring Script for macOS
# ------------------------------------------
# This script collects system metrics periodically and pushes them to Prometheus Pushgateway.
# It also logs all output with timestamps and manages log file size by truncating when too large.
#
# Key metrics collected:
# - CPU usage
# - Memory usage
# - Disk usage and disk I/O
# - Network packet loss and network I/O
# - Status of critical services (nginx, postgres, redis)
#
# Alerts are sent via Telegram when thresholds are exceeded.
#
# Author: VioletSoul
# Date: 2025-05-01
# ------------------------------------------

# --- Environment Setup ---

# Ensure standard system paths are included in PATH variable
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# Enable strict error handling:
# -e: exit on any command failure
# -u: treat unset variables as errors
# -o pipefail: pipeline returns failure if any command fails
set -euo pipefail

# --- Log File Configuration ---

LOG_FILE="./infra_monitor.log"       # Path to log file
MAX_LOG_SIZE=$((10 * 1024 * 1024))  # Maximum log file size in bytes (10 MB)

# Redirect all stdout and stderr to a process substitution that:
# - Prepends each line with a timestamp
# - Appends output to the log file
exec > >(
  while IFS= read -r line; do
    # Prepend timestamp in format [YYYY-MM-DD HH:MM:SS]
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $line"
  done | tee -a "$LOG_FILE"
) 2>&1

# --- Configuration and Thresholds ---

CONFIG_FILE="./infra_monitor.conf"   # Configuration file path

# Associative array of threshold values for alerts
typeset -A THRESHOLDS=(
  CPU_CRIT 95
  CPU_WARN 80
  MEM_CRIT 90
  MEM_WARN 70
  DISK_CRIT 90
  DISK_WARN 80
)

# Telegram bot credentials (set in config file)
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

# Prometheus Pushgateway URL
PROMETHEUS_PUSHGATEWAY="http://localhost:9091"

# Hostname for labeling metrics
INSTANCE_NAME=$(hostname)

# Services to monitor: service name => port number
typeset -A SERVICE_PORTS=(
  nginx 80
  postgres 5432
  redis 6379
)

# --- Variables to hold metrics ---

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

# --- Function: Check and truncate log file if too large ---
check_log_size() {
  # Check if log file exists
  if [[ -f "$LOG_FILE" ]]; then
    # Get current log file size in bytes
    local log_size
    log_size=$(stat -f%z "$LOG_FILE")

    # If log file size exceeds MAX_LOG_SIZE, truncate it
    if (( log_size > MAX_LOG_SIZE )); then
      echo "Log file too big (${log_size} bytes), truncating to last 1000 lines..."
      # Keep only last 1000 lines to preserve recent logs
      tail -n 1000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    fi
  fi
}

# --- Function: Load configuration file ---
load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
    echo "Configuration loaded from $CONFIG_FILE"
  else
    echo "Configuration file not found! Exiting."
    exit 1
  fi
}

# --- Function: Send alert via Telegram ---
send_alert() {
  local level=$1
  local message=$2
  echo "Sending alert: [$level] $message"

  # Only send if Telegram credentials are set
  if [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
    curl -s -X POST \
      -H 'Content-Type: application/json' \
      -d "{\"chat_id\":\"$TELEGRAM_CHAT_ID\",\"text\":\"[$level] $message\"}" \
      "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" >/dev/null
  fi
}

# --- Function: Check CPU usage ---
check_cpu() {
  echo "Checking CPU usage..."

  # Get CPU idle and system usage from top command, sum user + system CPU percentages
  local cpu_val
  cpu_val=$(top -l 2 -n 0 | grep "CPU usage" | tail -1 | awk '{print $3 + $5}' | sed 's/%//g')

  # Default to 0 if empty
  cpu_val=${cpu_val:-0}
  cpu_usage=$cpu_val

  # Compare with thresholds and send alerts if necessary
  if (( $(echo "$cpu_val >= ${THRESHOLDS[CPU_CRIT]}" | bc -l) )); then
    send_alert "CRITICAL" "CPU usage is at ${cpu_val}%"
  elif (( $(echo "$cpu_val >= ${THRESHOLDS[CPU_WARN]}" | bc -l) )); then
    send_alert "WARNING" "CPU usage is at ${cpu_val}%"
  fi
}

# --- Function: Check Memory usage ---
check_memory() {
  echo "Checking memory usage..."

  # Get page size and various page counts from vm_stat
  local page_size pages_active pages_inactive pages_wired pages_free pages_compressed pages_used pages_total
  local bytes_used bytes_total mem_val

  page_size=$(vm_stat | grep "page size of" | awk '{print $8}')
  page_size=${page_size:-4096}

  pages_active=$(vm_stat | awk '/Pages active:/ {print $3}' | tr -d '.')
  pages_inactive=$(vm_stat | awk '/Pages inactive:/ {print $3}' | tr -d '.')
  pages_wired=$(vm_stat | awk '/Pages wired down:/ {print $4}' | tr -d '.')
  pages_free=$(vm_stat | awk '/Pages free:/ {print $3}' | tr -d '.')
  pages_compressed=$(vm_stat | awk '/Pages occupied by compressor:/ {print $5}' | tr -d '.')

  # Validate all values are present
  for val in $pages_active $pages_inactive $pages_wired $pages_free $pages_compressed $page_size; do
    if [[ -z "$val" ]]; then
      echo "WARNING: vm_stat output incomplete, setting mem_usage=0"
      mem_usage=0
      return
    fi
  done

  # Calculate used and total pages
  pages_used=$((pages_active + pages_wired + pages_compressed))
  pages_total=$((pages_used + pages_inactive + pages_free))

  # Calculate bytes used and total bytes
  bytes_used=$((pages_used * page_size))
  bytes_total=$((pages_total * page_size))

  # Calculate memory usage percentage
  if (( bytes_total == 0 )); then
    mem_val=0
  else
    mem_val=$(awk "BEGIN {printf \"%.2f\", ($bytes_used / $bytes_total) * 100}")
  fi

  # Normalize decimal separator
  mem_val=$(echo "$mem_val" | tr ',' '.')

  mem_usage=$mem_val

  # Send alerts if thresholds exceeded
  if (( $(echo "$mem_val >= ${THRESHOLDS[MEM_CRIT]}" | bc -l) )); then
    send_alert "CRITICAL" "Memory usage is at ${mem_val}%"
  elif (( $(echo "$mem_val >= ${THRESHOLDS[MEM_WARN]}" | bc -l) )); then
    send_alert "WARNING" "Memory usage is at ${mem_val}%"
  fi
}

# --- Function: Check Disk usage ---
check_disk() {
  echo "Checking disk usage..."

  local disk_val disk_num
  local disk_path="/"

  # Get disk usage percentage for root partition
  disk_val=$(df "$disk_path" | tail -1 | awk '{print $5}' | tr -d '%')

  # Default to 0 if empty
  if [[ -z "$disk_val" ]]; then
    disk_usage=0
    return
  fi

  disk_num=${disk_val%%.*}
  disk_usage=$disk_val

  # Send alerts if thresholds exceeded
  if (( disk_num >= THRESHOLDS[DISK_CRIT] )); then
    send_alert "CRITICAL" "Disk usage on $disk_path is at ${disk_val}%"
  elif (( disk_num >= THRESHOLDS[DISK_WARN] )); then
    send_alert "WARNING" "Disk usage on $disk_path is at ${disk_val}%"
  fi
}

# --- Function: Check Disk I/O ---
check_disk_io() {
  echo "Checking disk I/O..."

  # Capture last line with disk0 stats from iostat output
  local line
  line=$(iostat -d 1 2 | awk '
    $1 == "disk0" {line = $0}
    END {print line}
  ')

  # If no data, set zero values
  if [[ -z "$line" ]]; then
    disk_read_ops=0
    disk_write_ops=0
    return
  fi

  # Extract read and write ops per second (3rd and 4th columns)
  disk_read_ops=$(echo "$line" | awk '{print $3}')
  disk_write_ops=$(echo "$line" | awk '{print $4}')

  # Validate numeric values, else set zero
  if ! [[ "$disk_read_ops" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    disk_read_ops=0
  fi
  if ! [[ "$disk_write_ops" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    disk_write_ops=0
  fi
}

# --- Function: Check Network Packet Loss ---
check_network() {
  echo "Checking network packet loss..."

  local loss_val

  # Ping Google's DNS 3 times and extract packet loss percentage
  loss_val=$(ping -c 3 8.8.8.8 | grep 'packet loss' | sed -E 's/.*, ([0-9]+(\.[0-9]+)?)% packet loss.*/\1/')

  # Default to 100% loss if empty
  if [[ -z "$loss_val" ]]; then
    network_loss=100
    return
  fi

  network_loss=$loss_val

  # Send alerts if thresholds exceeded
  if (( $(echo "$loss_val > 50" | bc -l) )); then
    send_alert "CRITICAL" "Network packet loss is at ${loss_val}%"
  elif (( $(echo "$loss_val > 20" | bc -l) )); then
    send_alert "WARNING" "Network packet loss is at ${loss_val}%"
  fi
}

# --- Function: Check Network I/O ---
check_network_io() {
  echo "Checking network I/O..."

  # Get default network interface name
  local iface
  iface=$(route get default 2>/dev/null | awk '/interface: / {print $2}')

  # If no interface found, set zero stats
  if [[ -z "$iface" ]]; then
    echo "Cannot determine default network interface"
    net_bytes_in=0
    net_bytes_out=0
    net_packets_in=0
    net_packets_out=0
    return
  fi

  # Extract bytes and packets in/out from netstat for the interface
  local in_bytes out_bytes in_pkts out_pkts
  in_bytes=$(netstat -ib | awk -v iface="$iface" '$1==iface {print $7; exit}')
  out_bytes=$(netstat -ib | awk -v iface="$iface" '$1==iface {print $10; exit}')
  in_pkts=$(netstat -ib | awk -v iface="$iface" '$1==iface {print $6; exit}')
  out_pkts=$(netstat -ib | awk -v iface="$iface" '$1==iface {print $9; exit}')

  # Assign values or zero if empty
  net_bytes_in=${in_bytes:-0}
  net_bytes_out=${out_bytes:-0}
  net_packets_in=${in_pkts:-0}
  net_packets_out=${out_pkts:-0}
}

# --- Function: Check Service Status ---
check_services() {
  echo "Checking services status..."

  local service port svc_status

  # Iterate over services and check if port is open on localhost
  for service port in ${(kv)SERVICE_PORTS}; do
    if nc -z localhost $port; then
      svc_status=1  # Service is up
    else
      svc_status=0  # Service is down
      send_alert "CRITICAL" "Service $service is DOWN!"
    fi
    service_statuses[$service]=$svc_status
  done
}

# --- Function: Push all collected metrics to Prometheus Pushgateway ---
push_all_metrics() {
  echo "Pushing all metrics to Pushgateway..."

  # Ensure no unset variables
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

  # Prepare Prometheus metrics payload
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

  # Append service status metrics
  for service port in ${(kv)SERVICE_PORTS}; do
    local svc_status=${service_statuses[$service]:-0}
    payload+=$'\n'
    payload+="service_status{service=\"$service\",port=\"$port\",instance=\"$INSTANCE_NAME\"} $svc_status"
  done

  # Log payload for debugging
  echo "Payload to push:"
  echo "$payload"

  # Push metrics to Prometheus Pushgateway
  curl -s -X POST --data-binary @- "$PROMETHEUS_PUSHGATEWAY/metrics/job/infra_monitor/instance/$INSTANCE_NAME" <<< "$payload"
}

# --- Main function ---
main() {
  # Load configuration file
  load_config

  # Setup trap to handle script termination gracefully
  trap "echo 'Script terminated'; exit 0" SIGINT SIGTERM

  # Infinite monitoring loop
  while true; do
    # Check and truncate log file if needed to prevent uncontrolled growth
    check_log_size

    # Collect metrics
    check_cpu
    check_memory
    check_disk
    check_disk_io
    check_network
    check_network_io
    check_services

    # Push metrics to Prometheus
    push_all_metrics

    # Wait 5 seconds before next iteration
    sleep 5
  done
}

# --- Script entry point ---
if [[ "${(%):-%N}" == "$0" ]]; then
  main "$@"
fi
