Script Description
------------------
This script is designed for infrastructure monitoring on macOS systems. It periodically (every 5 seconds) collects key metrics:
  - CPU usage
  - Memory usage (accurately accounting for active, wired, and compressed memory)
  - Disk usage
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
__________________
Usage: 
Run the script; it operates in an infinite loop, updating and pushing metrics to the Prometheus Pushgateway every 5 seconds.
------------------
