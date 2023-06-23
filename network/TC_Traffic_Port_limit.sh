cat << 'EOF' > /home/ubuntu/bandwidth-throttle.sh
#!/bin/bash
# Script:TC Traffic 
# Author: YuanLu
# Location:  Auckland, New Zealand
# Date: 23/06/2023

LIMIT=40mbit
START_PORT=10000
END_PORT=32768
IFACE="eth0"

if [ "$(id -u)" != "0" ]; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

while true; do
CONTAINER_IDS=$(docker ps --filter status=running | grep node_node | awk '{print $1}')

for CONTAINER_ID in $CONTAINER_IDS
do
    pid=$(docker inspect -f '{{.State.Pid}}' $CONTAINER_ID || true)

    tc_exists=$(nsenter -n -t $pid tc qdisc show dev "$IFACE" | grep "htb 1:" || true)
    iptables_exists_tcp=$(nsenter -n -t $pid iptables -t mangle -L POSTROUTING | grep "tcp spts:$START_PORT:$END_PORT MARK set 0xa" || true)
    iptables_exists_udp=$(nsenter -n -t $pid iptables -t mangle -L POSTROUTING | grep "udp spts:$START_PORT:$END_PORT MARK set 0xa" || true)

    if [ "$1" = "enable" ]; then
        if [ -n "$tc_exists" ] && [ -n "$iptables_exists_tcp" ] && [ -n "$iptables_exists_udp" ]; then
            echo "The rules already exist for container $CONTAINER_ID"
            continue
        fi
        echo "Network Namespace of Container $CONTAINER_ID enabling rate $LIMIT"
        nsenter -n -t $pid tc qdisc add dev "$IFACE" root handle 1: htb || true
        nsenter -n -t $pid tc class add dev "$IFACE" parent 1: classid 1:10 htb rate $LIMIT || true
        nsenter -n -t $pid tc filter add dev "$IFACE" parent 1:0 prio 1 handle 10 fw flowid 1:10 || true
        nsenter -n -t $pid iptables -t mangle -A POSTROUTING -p tcp --sport $START_PORT:$END_PORT -j MARK --set-mark 10 || true
        nsenter -n -t $pid iptables -t mangle -A POSTROUTING -p udp --sport $START_PORT:$END_PORT -j MARK --set-mark 10 || true
    elif [ "$1" = "disable" ]; then
        if [ -n "$tc_exists" ]; then
            nsenter -n -t $pid tc qdisc del dev "$IFACE" root || true
        fi
        if [ -n "$iptables_exists_tcp" ]; then
            nsenter -n -t $pid iptables -t mangle -D POSTROUTING -p tcp --sport $START_PORT:$END_PORT -j MARK --set-mark 10 || true
        fi
        if [ -n "$iptables_exists_udp" ]; then
            nsenter -n -t $pid iptables -t mangle -D POSTROUTING -p udp --sport $START_PORT:$END_PORT -j MARK --set-mark 10 || true
        fi
        echo "Network Namespace of Container $CONTAINER_ID disabling rate limit"
    else
        echo "No valid option selected, please choose 'enable' or 'disable'"
    fi
    done
    sleep 10
done
EOF

chmod 777 /home/ubuntu/bandwidth-throttle.sh
chown ubuntu:ubuntu /home/ubuntu/bandwidth-throttle.sh

bash /home/ubuntu/bandwidth-throttle.sh enable

cat << EOF > /etc/systemd/system/docker-throttle.service
[Unit]
Description=Throttle Docker Containers
After=docker.service
Requires=docker.service

[Service]
ExecStart=bash /home/ubuntu/bandwidth-throttle.sh enable
ExecStop=bash /home/ubuntu/bandwidth-throttle.sh disable
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl enable docker-throttle.service
systemctl start docker-throttle.service
