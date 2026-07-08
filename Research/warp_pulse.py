import urllib.parse
import urllib.request
import json
import yaml
import subprocess
import time
import sys
import os

VLESS_URL = "vless://3dd69f01-f8ea-412f-a538-f44cbd1154d1@3bd9.55dca.e048.f1-fef1f.yfjcs.com:443?type=tcp&encryption=none&host=&path=&headerType=none&quicSecurity=none&serviceName=&security=reality&flow=xtls-rprx-vision&fp=chrome&insecure=0&sni=osxapps.itunes.apple.com&pbk=egq3FRi4oqkJ-iJ40r-pk10g7tawGg6o9c4UDGOPDU4&sid=9824e11ad3a632f8#%F0%9F%87%AF%F0%9F%87%B5%E6%97%A5%E6%9C%AC-%E7%A7%BB%E5%8A%A8%E4%B8%93%E5%B1%9E1%E5%8F%B7-0.1%E5%80%8D%E7%8E%87"
MIHOMO_PATH = "./mihomo"
API_URL = "http://127.0.0.1:9090"

def generate_config():
    print("[*] Generating mihomo configuration...")
    parts = VLESS_URL[8:].split('#', 1)
    url_part = parts[0]
    name = urllib.parse.unquote(parts[1]) if len(parts) > 1 else "vless-node"

    auth_server = url_part.split('?')[0]
    uuid, server_port = auth_server.split('@', 1)
    server, port = server_port.split(':', 1)

    qs = url_part.split('?')[1] if '?' in url_part else ""
    query = urllib.parse.parse_qs(qs)

    node = {
        "name": name,
        "type": "vless",
        "server": server,
        "port": int(port),
        "uuid": uuid,
        "network": query.get('type', ['tcp'])[0],
        "tls": True,
        "udp": True,
        "flow": query.get('flow', [''])[0],
        "servername": query.get('sni', [''])[0],
        "reality-opts": {
            "public-key": query.get('pbk', [''])[0],
            "short-id": query.get('sid', [''])[0]
        },
        "client-fingerprint": query.get('fp', ['chrome'])[0]
    }

    config = {
        "mixed-port": 7890,
        "allow-lan": True,
        "mode": "rule",
        "log-level": "info",
        "ipv6": False,
        "external-controller": "127.0.0.1:9090",
        "tun": {
            "enable": True,
            "stack": "gvisor",
            "auto-route": True,
            "auto-detect-interface": True,
            "dns-hijack": ["any:53", "tcp://any:53"]
        },
        "dns": {
            "enable": True,
            "listen": "0.0.0.0:1053",
            "ipv6": False,
            "default-nameserver": ["223.5.5.5"],
            "enhanced-mode": "fake-ip",
            "fake-ip-range": "198.18.0.1/16",
            "nameserver": ["8.8.8.8", "1.1.1.1"]
        },
        "proxies": [node],
        "proxy-groups": [
            {
                "name": "Proxy",
                "type": "select",
                "proxies": [node['name'], "DIRECT"]
            }
        ],
        "rules": [
            "MATCH,Proxy"
        ]
    }

    with open("config.yaml", "w") as f:
        yaml.dump(config, f, allow_unicode=True)
    print(f"[*] Config saved with node: {name}")

def run_cmd(cmd, silent=False):
    if not silent:
        print(f"[*] Executing: {cmd}")
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if result.returncode != 0 and not silent:
        print(f"[!] Command failed: {cmd}\n{result.stderr}")
    return result.stdout.strip()

def api_put(path, payload):
    data = json.dumps(payload).encode('utf-8')
    req = urllib.request.Request(f"{API_URL}{path}", data=data, method='PUT')
    req.add_header('Content-Type', 'application/json')
    try:
        urllib.request.urlopen(req, timeout=5)
    except Exception as e:
        print(f"[!] API call to {path} failed: {e}")

def configure_warp():
    print("[*] Configuring WARP for MASQUE and normal tun mode...")
    run_cmd("warp-cli --accept-tos disconnect")
    run_cmd("warp-cli --accept-tos tunnel masque-options set h3-only")
    run_cmd("warp-cli --accept-tos tunnel protocol set MASQUE")
    # Using mode warp so it acts as a global VPN on macOS
    run_cmd("warp-cli --accept-tos mode warp")
    # Reset MTU just in case
    run_cmd("warp-cli --accept-tos tunnel mtu reset")

def wait_for_warp():
    print("[*] Waiting for WARP to connect...")
    for _ in range(15):
        status = run_cmd("warp-cli --accept-tos status", silent=True)
        if "Connected" in status:
            print("[*] WARP is Connected!")
            return True
        time.sleep(2)
    print("[!] WARP failed to connect.")
    return False

def check_colo():
    print("[*] Checking Cloudflare colo...")
    try:
        # Since WARP is in global mode, regular urllib request to 1.1.1.1 goes through the tunnel
        req = urllib.request.Request("http://1.1.1.1/cdn-cgi/trace")
        with urllib.request.urlopen(req, timeout=10) as response:
            text = response.read().decode('utf-8')
            for line in text.split("\n"):
                if line.startswith("colo="):
                    print(f"[+] Current colo: {line.split('=')[1]}")
                    return line.split('=')[1]
    except Exception as e:
        print(f"[!] Request failed: {e}")
    return None

def main():
    if os.geteuid() != 0:
        print("[!] This script requires root privileges to configure TUN routing.")
        print("[!] Please run again with: sudo python3 warp_pulse.py")
        sys.exit(1)

    # 1. Generate Config
    generate_config()

    # 2. Configure WARP offline
    configure_warp()

    # 3. Start mihomo
    print("[*] Starting mihomo TUN...")
    run_cmd("pkill mihomo", silent=True) # Kill any existing instance
    mihomo_proc = subprocess.Popen([MIHOMO_PATH, "-d", "."], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(3) # Wait for TUN to establish

    try:
        # Ensure proxy is set to the VLESS node first
        api_put("/proxies/Proxy", {"name": VLESS_URL.split('#')[1] if '#' in VLESS_URL else "vless-node"})
        
        # 4. Connect WARP
        print("[*] Triggering WARP connection via Asian proxy...")
        run_cmd("warp-cli --accept-tos connect")
        
        if not wait_for_warp():
            sys.exit(1)

        # Let the connection stabilize
        time.sleep(5)
        colo1 = check_colo()

        # 5. Soft Pulse (Connection Migration)
        print("\n[*] >>> INITIATING SOFT PULSE <<<")
        print("[*] Switching proxy to DIRECT via API...")
        api_put("/proxies/Proxy", {"name": "DIRECT"})
        print("[*] Route changed to DIRECT. Waiting 5s for QUIC migration...")
        time.sleep(5)

        # 6. Verify NRT retention
        print("\n[*] Verifying connection migration success...")
        colo2 = check_colo()
        
        if colo1 == colo2 and colo2:
            print(f"\n[SUCCESS] Locked {colo2} perfectly through connection migration!")
        else:
            print("\n[FAILED] Colo changed or connection lost.")

    finally:
        # 7. Cleanup
        print("\n[*] Cleaning up...")
        mihomo_proc.terminate()
        run_cmd("pkill mihomo", silent=True)
        print("[*] mihomo closed. Network restored.")
        
        # Final trace to prove it survived the TUN destruction (which you experienced with Shadowrocket)
        print("[*] Final check after mihomo shutdown:")
        time.sleep(3)
        check_colo()

if __name__ == "__main__":
    main()
