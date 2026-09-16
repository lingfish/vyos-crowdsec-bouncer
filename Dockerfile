# Base is Alpine; add curl for the VyOS HTTPS API calls.
FROM crowdsecurity/custom-bouncer:v0.0.19

RUN apk add --no-cache curl

COPY bouncer.yaml /crowdsec-custom-bouncer.yaml
COPY vyos-bouncer.sh /opt/vyos-crowdsec-bouncer/vyos-bouncer.sh
COPY vyos-bouncer.conf /etc/crowdsec/vyos-bouncer.conf

RUN chmod +x /opt/vyos-crowdsec-bouncer/vyos-bouncer.sh \
 && chmod 600 /etc/crowdsec/vyos-bouncer.conf \
 && mkdir -p /var/spool/crowdsec