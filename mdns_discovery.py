import socket
from zeroconf import IPVersion, ServiceInfo, Zeroconf
import logging

logger = logging.getLogger("mDNS")

class LocalDiscovery:
    def __init__(self, user_id, port=8766):
        self.user_id = user_id
        self.port = port
        self.zeroconf = Zeroconf(ip_version=IPVersion.V4Only)
        self.service_info = None

    def _get_ip(self):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            # doesn't even have to be reachable
            s.connect(('10.255.255.255', 1))
            IP = s.getsockname()[0]
        except Exception:
            IP = '127.0.0.1'
        finally:
            s.close()
        return IP

    def start_broadcast(self):
        ip = self._get_ip()
        logger.info(f"Starting mDNS broadcast for {self.user_id} on {ip}:{self.port}")
        
        # Service type: _acp._tcp.local.
        # Instance name: MyBot_user_id
        self.service_info = ServiceInfo(
            "_acp._tcp.local.",
            f"MyBot_{self.user_id}._acp._tcp.local.",
            addresses=[socket.inet_aton(ip)],
            port=self.port,
            properties={"user_id": self.user_id, "version": "1.0.0"},
            server=f"mybot-{self.user_id}.local.",
        )
        self.zeroconf.register_service(self.service_info)

    def stop_broadcast(self):
        if self.service_info:
            logger.info("Stopping mDNS broadcast")
            self.zeroconf.unregister_service(self.service_info)
            self.zeroconf.close()
