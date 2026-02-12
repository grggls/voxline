CLUSTER_NAME := voxline

.PHONY: cluster-up cluster-down cluster-stop cluster-start cluster-status \
       foundations-up foundations-down foundations-status \
       infra-up infra-down infra-status \
       ollama-up ollama-pull ollama-benchmark \
       gateway-build gateway-deploy \
       build test lint

cluster-up:
	@bash infra/kind/create-cluster.sh

cluster-down:
	@echo ""
	@echo "  This will PERMANENTLY DELETE the '$(CLUSTER_NAME)' cluster."
	@echo "   All pods, volumes, data, and configuration will be destroyed."
	@echo ""
	@read -p "Type 'yes' to confirm deletion: " confirm && \
		[ "$$confirm" = "yes" ] || { echo "Aborted."; exit 1; }
	@kind delete cluster --name $(CLUSTER_NAME)
	@echo "Cluster '$(CLUSTER_NAME)' deleted."

cluster-stop:
	@bash infra/kind/stop-cluster.sh

cluster-start:
	@bash infra/kind/start-cluster.sh

cluster-status:
	@echo "=== Cluster Status ==="
	@kubectl cluster-info --context kind-$(CLUSTER_NAME) 2>/dev/null || { echo "Cluster is not running."; exit 1; }
	@echo ""
	@echo "=== Nodes ==="
	@kubectl get nodes
	@echo ""
	@echo "=== All Pods ==="
	@kubectl get pods -A --sort-by=.metadata.namespace
	@echo ""
	@echo "=== Resource Usage ==="
	@kubectl top nodes 2>/dev/null || echo "(metrics-server not yet installed — run 'make foundations-up')"

# === Foundations (Observability, Metrics, Storage) ===

foundations-up:
	@bash infra/helm/deploy-foundations.sh

foundations-down:
	helm uninstall otel-collector -n monitoring || true
	helm uninstall kube-prometheus-stack -n monitoring || true
	helm uninstall metrics-server -n kube-system || true

foundations-status:
	@echo "=== Foundations Status ==="
	@echo ""
	@echo "--- metrics-server ---"
	@kubectl top nodes 2>/dev/null || echo "  Not ready"
	@echo ""
	@echo "--- Monitoring Pods ---"
	@kubectl get pods -n monitoring
	@echo ""
	@echo "--- Grafana ---"
	@echo "  URL: http://localhost:30000"
	@echo "  Credentials: admin / voxline"

# === Infrastructure (NATS, MongoDB, Redis) ===

infra-up:
	@bash infra/helm/deploy-infra.sh

infra-down:
	helm uninstall nats mongodb redis -n voxline || true

infra-status:
	@echo "=== Infrastructure Status ==="
	@echo ""
	@kubectl get pods -n voxline
	@echo ""
	@kubectl get pvc -n voxline

# === Ollama (AI Model Runtime) ===

ollama-up:
	kubectl apply -f infra/k8s/ollama.yaml

ollama-pull:
	bash infra/k8s/ollama-pull-models.sh

ollama-benchmark:
	bash infra/k8s/ollama-benchmark.sh

# === Gateway Service ===

gateway-build:
	docker build -t voxline/gateway:latest -f gateway/Dockerfile .
	kind load docker-image voxline/gateway:latest --name voxline

gateway-deploy: gateway-build
	kubectl apply -f infra/k8s/gateway.yaml
	kubectl rollout restart deployment/gateway -n voxline
	kubectl rollout status deployment/gateway -n voxline --timeout=60s

# === TypeScript Build, Test, Lint ===

build:
	npm run build

test:
	npm run test

lint:
	npm run lint
