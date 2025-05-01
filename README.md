Script Description
------------------
This is an advanced infrastructure monitoring script designed for macOS environments running the zsh shell. It performs periodic health checks on critical system resources and services, including CPU usage, memory consumption, disk space, network packet loss, and the status of key services (e.g., nginx, PostgreSQL, Redis).
The script integrates with external systems by:

	•	Sending alert notifications via Telegram when resource usage exceeds configurable thresholds or services become unavailable.
	•	Pushing performance metrics to a Prometheus Pushgateway endpoint for centralized monitoring and visualization.
 
It features robust logging with timestamped entries, runs checks concurrently for efficiency, and gracefully handles termination signals. This tool is ideal for system administrators and DevOps engineers seeking automated, real-time monitoring of their macOS infrastructure.
------------------
