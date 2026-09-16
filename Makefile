IMAGE     ?= vyos-crowdsec-bouncer
REGISTRY  ?= ghcr.io/yourorg
VERSION   ?= $(shell git describe --tags --always 2>/dev/null || echo latest)
ENGINE    ?= podman

.PHONY: build test dry-run push clean

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