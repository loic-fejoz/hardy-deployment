IMAGE_NAME ?= cxlb-hardy:latest
BASE_IMAGE ?= cxlb-docker-gnuradio-3.10:latest
CONTAINER_NAME ?= cxlb-hardy-test

.PHONY: all build run-test clean

all: build

build:
	docker build --build-arg BASE_IMAGE=$(BASE_IMAGE) -t $(IMAGE_NAME) .

run-test: build
	@echo "==> Starting test container $(CONTAINER_NAME)..."
	@docker rm -f $(CONTAINER_NAME) 2>/dev/null || true
	@docker run --rm -d \
		--name $(CONTAINER_NAME) \
		-e NODE_EID="ipn:100.0" \
		-e LTP_ENGINE_ID=100 \
		-e LTP_PEERS="200=ipn:200.0, 300=dtn://f4jxq/" \
		-e RF_FREQ="434000000" \
		-e IGNORE_FLOWGRAPH_FAILURE=true \
		-e AUTO_EXIT=false \
		$(IMAGE_NAME)
	@echo "==> Waiting for Hardy BPA to initialize..."
	@sleep 3
	@echo "==> Checking Hardy BPA presence..."
	docker exec $(CONTAINER_NAME) hardy-bpa-server --version || true
	@echo "==> Checking DTN utilities and bp tool availability..."
	docker exec $(CONTAINER_NAME) which dtnping dtnsend dtnprint dtnfiles dtnbasket hdy-stats bp
	@echo "==> Testing DTN ping against local Hardy BPA echo service..."
	docker exec $(CONTAINER_NAME) dtnping -c 2 ipn:100.7
	@echo "==> Testing bp ping over TCPCLv4 against local Hardy BPA echo service..."
	docker exec $(CONTAINER_NAME) bp ping --cla tcpclv4 -c 3 -w 5s ipn:100.7 127.0.0.1:4556
	@echo "==> Inspecting generated Hardy configuration..."
	docker exec $(CONTAINER_NAME) cat /etc/hardy/hardy.yaml
	@echo "==> Checking compiled GNU Radio flowgraph..."
	docker exec $(CONTAINER_NAME) ls -la /opt/cxlb-hardy/flowgraphs
	@echo "==> Checking running processes in container..."
	docker exec $(CONTAINER_NAME) ps aux
	@echo "==> Stopping test container..."
	@docker stop $(CONTAINER_NAME)
	@echo "==> Testing scenario script execution with bp ping..."
	@docker run --rm \
		-e NODE_EID="ipn:100.0" \
		-e LTP_ENGINE_ID=100 \
		-e IGNORE_FLOWGRAPH_FAILURE=true \
		-e AUTO_EXIT=true \
		-e SCENARIO_SCRIPT="/opt/cxlb-hardy/scenario_test.sh" \
		--entrypoint /bin/bash \
		$(IMAGE_NAME) -c 'echo -e "#!/bin/bash\nset -e\necho Running bp ping from scenario...\nbp ping --cla tcpclv4 -c 3 -w 5s ipn:100.7 127.0.0.1:4556\necho Scenario bp ping successful\n" > /opt/cxlb-hardy/scenario_test.sh && chmod +x /opt/cxlb-hardy/scenario_test.sh && exec /entrypoint.sh'
	@echo "==> Smoke test completed successfully!"

clean:
	@docker rm -f $(CONTAINER_NAME) 2>/dev/null || true
	@docker rmi $(IMAGE_NAME) 2>/dev/null || true
