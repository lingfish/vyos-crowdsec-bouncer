IMAGE     ?= vyos-crowdsec-bouncer
REGISTRY  ?= ghcr.io/yourorg
VERSION   ?= $(shell git describe --tags --always 2>/dev/null || echo latest)
ENGINE    ?= podman

.PHONY: build test dry-run push clean lab-up lab-test-expiry lab-test-ipv6 lab-test-forward lab-down lab

build:
	$(ENGINE) build -t $(IMAGE):$(VERSION) .

test:
	./test/test-vyos-bouncer.sh

dry-run:
	./test/test-vyos-bouncer.sh --dry-run

push: build
	$(ENGINE) push $(REGISTRY)/$(IMAGE):$(VERSION)

clean:
	rm -rf test/tmp spool

lab-up:
	./lab/provision.sh

lab-test-expiry:
	./lab/test-expiry.sh

lab-test-ipv6:
	./lab/test-ipv6.sh

lab-test-forward:
	./lab/test-forward.sh

lab-down:
	./lab/down.sh

lab: lab-up lab-test-expiry lab-test-ipv6 lab-test-forward