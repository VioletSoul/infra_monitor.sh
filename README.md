![Shell](https://img.shields.io/badge/Shell-zsh-4E9A06?style=flat&logo=gnu-bash&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-000000?style=flat&logo=apple&logoColor=white)
![Prometheus](https://img.shields.io/badge/Prometheus-E6522C?style=flat&logo=prometheus&logoColor=white)
![Pushgateway](https://img.shields.io/badge/Pushgateway-✓-orange)
![Telegram](https://img.shields.io/badge/Telegram-26A5E4?style=flat&logo=telegram&logoColor=white)
![Monitoring](https://img.shields.io/badge/Monitoring-✓-brightgreen)
![Alerting](https://img.shields.io/badge/Alerting-✓-red)
![Service Health](https://img.shields.io/badge/Service%20Health-✓-blue)
![License](https://img.shields.io/badge/license-MIT-green.svg)
![Repo Size](https://img.shields.io/github/repo-size/VioletSoul/infra_monitor.sh)
![Code Size](https://img.shields.io/github/languages/code-size/VioletSoul/infra_monitor.sh)

Script Description
------------------
This script is designed for infrastructure monitoring on macOS systems. It periodically (every 5 seconds) collects key metrics:
  - CPU usage
  - Memory usage (accurately accounting for active, wired, and compressed memory)
  - Disk usage
  - Disk I/O operations (read and write operations per second on the main disk)
  - Network packet loss
  - Status of critical services (e.g., nginx, postgres, redis)

The collected metrics are pushed to a Prometheus Pushgateway for aggregation and visualization.
When configured thresholds (warning and critical) are exceeded, the script sends alerts via Telegram.

Key Features
 - Automatic configuration loading from a config file
 - Timestamped logging of all output
 - Alert notifications sent to Telegram
 - Service health checks on specified ports
 - Metrics publishing to Prometheus Pushgateway, enabling integration with Prometheus and other monitoring systems
 - Disk I/O monitoring using `iostat` for read/write operations per second
 - Network I/O monitoring using `netstat` for bytes and packets transmitted and received
------------------
In the script, the following types of data (metrics) are sent through the Prometheus Pushgateway:
  - cpu_usage - CPU usage percentage (gauge)
  - memory_usage - Memory usage percentage (gauge)
  - disk_usage - Disk usage percentage (gauge)
  - disk_read_ops - Disk read operations per second (gauge)
  - disk_write_ops - Disk write operations per second (gauge)
  - network_packet_loss - Network packet loss percentage (gauge)
  - net_bytes_in - Network bytes received (gauge)
  - net_bytes_out - Network bytes transmitted (gauge)
  - net_packets_in - Network packets received (gauge)
  - net_packets_out - Network packets transmitted (gauge)
  - service_status - Status of services (nginx, postgres, redis) with labels `service` and `port`, values are 1 (service is up) or 0 (service is down) (gauge)
__________________
Usage: 
Run the script; it operates in an infinite loop, updating and pushing metrics to the Prometheus Pushgateway every 5 seconds.
------------------
