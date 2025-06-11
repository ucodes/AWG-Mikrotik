# Overview.

	Covers implementation steps for Docker image build of WireGuard-Go fork from official AmneziaWG repository and configuration of RouterOS running the AmneziaWG client in a container.
The image is built on Ubuntu 24.04.2 LTS amd64 and run on Mikrotik 7.19.1 arm64 platform.
Mikrotik configuration provides transparent routing to AmneziaWG container running on a server: RouterOS marks connections and sends to a local container, the container wraps the traffic into the AWG tunnel, AWG container on the VPS server side receives the traffic, the traffic goes through the NAT rules and goes to the Internet. Reverse routing is done with help of MASQUERADE in local IPtables on a server. 

## IPs used.

Mikrotik containers network 172.17.1.0/30
AWG network 10.8.1.0/24
Mikrotik AWG client Address 10.8.1.7/32

## Image build.

### 1. install latest Docker and Buildx:

```bash
# Add Docker's official GPG key:
sudo apt-get update
sudo apt-get install ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update

sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

sudo groupadd docker
sudo usermod -aG docker ${USER}
reboot
```

### 2. download and install go

```bash
rm -rf /usr/local/go && tar -C /usr/local -xzf go1.24.3.linux-amd64.tar.gz
export PATH=$PATH:/usr/local/go/bin
go version
apt install make
```

### 3. install cross-platform emulator for Docker images to support ARM64 https://help.mikrotik.com/docs/spaces/ROS/pages/84901929/Container
```bash
docker buildx ls
docker run --privileged --rm tonistiigi/binfmt --install all
```

### 4. build and export image for Mikrotik
```bash
#copy wireguard-fs folder and Dockerfile to a project folder on a server
docker buildx build --build-arg ARCHITECTURE=arm64 --no-cache --progress=plain --platform linux/arm64/v8 --output=type=docker --tag docker-awg-arm64:latest . && docker save docker-awg-arm64:latest > docker-awg-arm64.tar
```

## Mikrotik config.

### 1. Update FW to the latest (RouterOS and RouterBOARD) https://help.mikrotik.com/docs/spaces/ROS/pages/328142/Upgrading+and+installation
### 2. Format external drive
```bash
	/disk/print
	/disk/format usb1  file-system=ext4
```
### 3. install extra package https://mikrotik.com/download
### 4. enable container support
```bash
/system/device-mode/update container=yes
#followed by reboot by a power
```
### 5. Routing config
```bash
#create VPN routing table
/routing table 
add disabled=no fib name=routing_to_vpn

#create to VPN address list (all internet traffic to VPN)
/ip firewall address-list
add address=0.0.0.0/0 list=to_vpn

#address list with private IPs to bypass VPN and have RouterOS accessible
/ip firewall address-list
add address=10.0.0.0/8 list=RFC1918
add address=172.16.0.0/12 list=RFC1918
add address=192.168.0.0/16 list=RFC1918

#accept private IPs (must be a higher priority than routing_to_vpn and mss mangle rules)
/ip firewall mangle
add action=accept chain=prerouting dst-address-list=RFC1918 in-interface-list=!WAN

#add a transit traffic rule to mark traffic for "to_vpn" address list 
/ip firewall mangle
add action=mark-connection chain=prerouting connection-mark=no-mark dst-address-list=to_vpn in-interface-list=!WAN \
    new-connection-mark=to-vpn-connmark passthrough=yes

#a transit traffic rule sending to "routing_to_vpn" routing table for routing
add action=mark-routing chain=prerouting connection-mark=to-vpn-connmark in-interface-list=!WAN new-routing-mark=routing_to_vpn \
    passthrough=yes

#create awg container veth
/interface veth
add address=172.17.1.2/30 gateway=172.17.1.1 gateway6="" name=docker-awg-veth

#assign IP to RouterOS
/ip address
add interface=docker-awg-veth address=172.17.1.1/30

#update mss for container traffic (must be after RFC1918 rule)
/ip firewall mangle
add action=change-mss chain=forward new-mss=1360 out-interface=docker-awg-veth passthrough=yes protocol=tcp tcp-flags=syn tcp-mss=1453-6553

#add a default route in "routing_to_vpn" routing table to send all traffic to AWG container
/ip route
add distance=1 dst-address=0.0.0.0/0 gateway=172.17.1.2 routing-table=routing_to_vpn

#Create a source NAT for all outgoing traffic to containers:
/ip firewall nat
add action=masquerade chain=srcnat out-interface=docker-awg-veth comment="Outgoing NAT for containers"
```

### 6. Create a new client connection on a server and update wg0.conf with allowed IPs (allowed - 0.0.0.0/0, disallowed IPs - containers network (172.17.1.0/30), AWG network (10.8.1.0/24), server public IP/32 (Endpoint in wg0.conf)) using calc https://www.procustodibus.com/blog/2021/03/wireguard-allowedips-calculator/ and remove IPv6

### 7. create container mounts and run the container
```bash
#copy docker-awg-arm64.tar to /usb1
#create usb1/tmp directory in winbox
#create usb1/AWG/conf directory in winbox
#copy wg0.conf to usb1/AWG/conf 
#create usb1/AWG/container directory in winbox

/container mounts
add dst=/etc/amnezia/amneziawg/ name=awg_conf src=/usb1/AWG/conf

/container config
set tmpdir=usb1/tmp

/container
add hostname=amnezia interface=docker-awg-veth logging=yes start-on-boot=yes mounts=awg_conf root-dir=/usb1/AWG/container file=usb1/docker-awg-arm64.tar
```

## AWG server config.

By default, AmneziaWG client runs w/o a NAT in the container, therefore Mikrotik containers network (172.17.1.0/30) must be added/allowed on a server
```bash
#on a server
docker container ls
#check for awg container name and shell to it
docker exec -it amnezia-awg bash
wg-quick down /opt/amnezia/awg/wg0.conf
vi /opt/amnezia/awg/wg0.conf
#check for the Mikrotik client [Peer] and add containers network to AllowedIPs (AllowedIPs = 10.8.1.7/32, 172.17.1.0/30)
#save
vi /opt/amnezia/start.sh
#add MASQUERADE rules to the end

iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables -t nat -A POSTROUTING -o eth1 -j MASQUERADE
#save
#start the server
wg-quick up /opt/amnezia/awg/wg0.conf
```

## Troubleshooting.

docker container exec -it, docker container logs, torch, tcpdump, wg-quick, awg-quick

## Tags.

AmneziaWG, Amnezia, AWG, WireGuard, WireGuard-Go, Docker, container, client, Mikrotik, ARM64

