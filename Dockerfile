# Minimal image: serve CrowdSec's active decisions as a static newline-
# delimited list that VyOS firewall remote-groups poll. No privileged access,
# no VyOS HTTPS API, no host firewall writes. busybox httpd binds loopback
# only (host networking) and serves the list written by the refresh loop.

FROM alpine:3.21

RUN apk add --no-cache curl bash jq busybox-extras

COPY vyos-bouncer.sh /opt/vyos-crowdsec-bouncer/vyos-bouncer.sh
COPY entrypoint.sh /opt/vyos-crowdsec-bouncer/entrypoint.sh
COPY vyos-bouncer.conf /etc/crowdsec/vyos-bouncer.conf

RUN chmod +x /opt/vyos-crowdsec-bouncer/vyos-bouncer.sh \
             /opt/vyos-crowdsec-bouncer/entrypoint.sh \
 && chmod 600 /etc/crowdsec/vyos-bouncer.conf \
 && mkdir -p /www

ENTRYPOINT ["/opt/vyos-crowdsec-bouncer/entrypoint.sh"]