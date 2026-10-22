IMAGE_NAME ?= cxlb-hardy:latest
CONTAINER_NAME ?= cxlb-hardy-test

.PHONY: all build run-test clean

all: build

build:
	docker build -t $(IMAGE_NAME) .

run-test: build
	@echo "==> Starting test container $(CONTAINER_NAME)..."
	@docker rm -f $(CONTAINER_NAME) 2>/dev/null || true
	@docker run --rm -d \
		--name $(CONTAINER_NAME) \
		-e NODE_EID="ipn:100.0" \
		-e LTP_ENGINE_ID=100 \
		-e LTP_PEERS="200=ipn:200.0, 300=dtn://f4jxq/" \
		-e IGNORE_FLOWGRAPH_FAILURE=true \
		-e AUTO_EXIT=false \
		$(IMAGE_NAME)
	@echo "==> Waiting for Hardy BPA to initialize..."
	@sleep 3
	@echo "==> Checking Hardy BPA presence..."
	docker exec $(CONTAINER_NAME) hardy-bpa-server --version || true
	@echo "==> Checking DTN utilities availability..."
	docker exec $(CONTAINER_NAME) which dtnping dtnsend dtnprint dtnfiles dtnbasket hdy-stats
	@echo "==> Testing DTN ping against local Hardy BPA echo service..."
	docker exec $(CONTAINER_NAME) dtnping -c 2 ipn:100.7
	@echo "==> Inspecting generated Hardy configuration..."
	docker exec $(CONTAINER_NAME) cat /etc/hardy/hardy.yaml
	@echo "==> Checking compiled GNU Radio flowgraph..."
	docker exec $(CONTAINER_NAME) ls -la /opt/cxlb-hardy/flowgraphs
	@echo "==> Checking running processes in container..."
	docker exec $(CONTAINER_NAME) ps aux
	@echo "==> Stopping test container..."
	@docker stop $(CONTAINER_NAME)
	@echo "==> Smoke test completed successfully!"

clean:
	@docker rm -f $(CONTAINER_NAME) 2>/dev/null || true
	@docker rmi $(IMAGE_NAME) 2>/dev/null || true
