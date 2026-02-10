CLUSTER_NAME := voxline

.PHONY: cluster-up cluster-down cluster-stop cluster-start cluster-status \
       foundations-up foundations-down foundations-status \
       infra-up infra-down infra-status

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
