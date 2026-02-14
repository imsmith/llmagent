VERSION ?= 0.3.0
REGISTRY ?= ghcr.io/imsmith
IMAGE := $(REGISTRY)/llmagent

.PHONY: build test release docker-build docker-push docker-run clean

build:
	mix deps.get && mix compile

test:
	mix test

release:
	MIX_ENV=prod mix release llmagent

docker-build:
	docker build -t $(IMAGE):$(VERSION) -t $(IMAGE):latest .

docker-push:
	docker push $(IMAGE):$(VERSION)
	docker push $(IMAGE):latest

docker-run:
	docker run --rm -e LLMAGENT_API_HOST=$(LLMAGENT_API_HOST) $(IMAGE):$(VERSION)

clean:
	rm -rf _build deps
