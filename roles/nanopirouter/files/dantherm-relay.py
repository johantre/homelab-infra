#!/usr/bin/env python3
"""UDP port 6400 relay: LAN1 broadcasts → Dantherm on LAN2, responses back."""
import os
import socket
import time
import logging

DST_IP = os.environ['DANTHERM_IP']
LAN1_PREFIX = os.environ['LAN1_PREFIX']
PORT = 6400
CLIENT_TTL = 10

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(message)s',
                    handlers=[logging.StreamHandler()])

clients = {}

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
sock.bind(('', PORT))

logging.info(f"Dantherm relay started on :{PORT} → {DST_IP}:{PORT}")

while True:
    data, (src_ip, src_port) = sock.recvfrom(65535)
    now = time.time()

    if src_ip.startswith(LAN1_PREFIX):
        clients[src_ip] = (src_port, now)
        sock.sendto(data, (DST_IP, PORT))

    elif src_ip == DST_IP:
        stale = [ip for ip, (_, ts) in clients.items() if now - ts > CLIENT_TTL]
        for ip in stale:
            del clients[ip]
        for client_ip, (client_port, _) in clients.items():
            sock.sendto(data, (client_ip, client_port))
