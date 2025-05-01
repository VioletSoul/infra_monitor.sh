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
