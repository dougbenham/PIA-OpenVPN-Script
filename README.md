# PIA, OpenVPN, qBittorrent and Port Forwarding

The reason for the `--interface` usages on cURL is because I have the VPN routes unbound (you can see how in the `sample.ovpn`). In qBittorrent, I have it bind to the `OpenVPN TAP` network interface.

1. So upon connecting to PIA with OpenVPN it requests port forwarding.
2. It kills any active qBittorrent processes.
3. It takes the port that was given by PIA and puts it into qBittorrent's settings as the incoming port.
4. It starts qBittorrent.
5. It renews the port binding every 14 minutes.