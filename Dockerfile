ARG ALPINE_VERSION=3.21
ARG GOLANG_VERSION=1.24rc1
#Change ARCHITECTURE argument to "arm64" or "arm" or "amd64"
ARG ARCHITECTURE=default

#--------------------------------Builder--------------------------------

FROM golang:${GOLANG_VERSION}-alpine${ALPINE_VERSION} AS builder

RUN apk update && apk add --no-cache git make bash build-base linux-headers
RUN git clone https://github.com/amnezia-vpn/amneziawg-go.git
RUN git clone https://github.com/amnezia-vpn/amneziawg-tools.git
RUN cd /go/amneziawg-go && \
    GOOS=linux GOARCH=${ARCHITECTURE} make
RUN cd /go/amneziawg-tools/src && \
    GOOS=linux GOARCH=${ARCHITECTURE} make

#--------------------------------Image--------------------------------

FROM alpine:${ALPINE_VERSION}
RUN set -ex; \
	apk update && apk add --no-cache bash openrc iptables ip6tables iptables-legacy iproute2 openresolv  \
    && mkdir -p /etc/amnezia/amneziawg/

COPY --from=builder /go/amneziawg-go/amneziawg-go /usr/bin/amneziawg-go
COPY --from=builder /go/amneziawg-tools/src/wg /usr/bin/awg
COPY --from=builder /go/amneziawg-tools/src/wg-quick/linux.bash /usr/bin/awg-quick
COPY wireguard-fs /

RUN \
#Prevents unnecessary tty instances from starting.
    sed -i 's/^\(tty\d\:\:\)/#\1/' /etc/inittab && \
#Propagates Docker environment variables to each OpenRC service.
    sed -i \
        -e 's/^#\?rc_env_allow=.*/rc_env_allow="\*"/' \
#Lets OpenRC know it’s running in a Docker container.
        -e 's/^#\?rc_sys=.*/rc_sys="docker"/' \
        /etc/rc.conf && \
#Makes sure the /run directory is set up appropriately for a Docker container.
    sed -i \
        -e 's/VSERVER/DOCKER/' \
#Ensures the needed /run/openrc directory exists.
        -e 's/checkpath -d "$RC_SVCDIR"/mkdir "$RC_SVCDIR"/' \
        /usr/libexec/rc/sh/init.sh && \
#Prevents an ignorable error message from the unneeded hwdrivers and machine-id services.
    rm \
        /etc/init.d/hwdrivers \
        /etc/init.d/machine-id
#Prevents awg-quick from attempting to set sysctl parameters that have already been set (preventing it from starting up).
RUN sed -i 's/cmd sysctl -q \(.*\?\)=\(.*\)/[[ "$(sysctl -n \1)" != "\2" ]] \&\& \0/' /usr/bin/awg-quick

RUN rm /usr/sbin/iptables && ln -s /usr/sbin/iptables-legacy /usr/sbin/iptables 
RUN rm /usr/sbin/ip6tables && ln -s /usr/sbin/ip6tables-legacy /usr/sbin/ip6tables

#Makes wg-quick executable and sets up wg-quick to be run as an OpenRC service (via the /etc/init.d/wg-quick service file copied into the image as part of the earlier COPY command).
RUN chmod u+x /etc/init.d/wg-quick
RUN rc-update add wg-quick default

RUN echo -e " \n\
    net.ipv4.ip_forward = 1 \n\
	net.ipv6.conf.default.forwarding=1 \n\
	net.ipv6.conf.all.forwarding = 1 \n\ 
    " | sed -e 's/^\s\+//g' | tee -a /etc/sysctl.conf

#Prevents unnecessary tty instances from starting.	
RUN sed -i 's/^tty/#tty/' /etc/inittab
#Boots OpenRC on container start. OpenRC service in the image will start up a WireGuard interface for each WireGuard configuration file it finds in its /etc/amnezia/amneziawg directory, using the wg-quick program.
ENTRYPOINT ["/sbin/init"]