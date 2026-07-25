CLUSTER_TARGETS := \
	-target=module.vpc \
	-target=module.eks \
	-target=module.karpenter \
	-target=aws_iam_role.ebs_csi_driver \
	-target=aws_iam_role_policy_attachment.ebs_csi_driver \
	-target=aws_eks_addon.ebs_csi_driver \
	-target=aws_eks_pod_identity_association.ebs_csi_driver \
	-target=aws_iam_role.efs_csi_driver \
	-target=aws_iam_role_policy_attachment.efs_csi_driver \
	-target=aws_eks_addon.efs_csi_driver \
	-target=aws_eks_pod_identity_association.efs_csi_driver

# Phase-1 plan: AWS-only resources (VPC, EKS, Karpenter, CSI addons).
# Use this on a fresh deploy before the cluster exists — does not require
# a live Kubernetes API.
plan-cluster:
	terraform plan $(CLUSTER_TARGETS) -out=tfplan

# Phase-2 plan: all workloads. Requires a running cluster.
plan-workloads:
	terraform plan -out=tfplan

# Fast plan — skips state refresh. Use for iteration when no out-of-band
# changes have been made. Requires a running cluster.
plan:
	terraform plan -refresh=false -out=tfplan

# Apply the last saved plan file.
apply:
	terraform apply tfplan

# Phase-1 apply: cluster foundation.
apply-cluster:
	terraform apply -auto-approve $(CLUSTER_TARGETS)

# Phase-2 apply: all workloads after the cluster is running.
apply-workloads:
	terraform apply -auto-approve

# Phase-1 destroy: drain GPU workloads and remove all Kubernetes/Helm resources.
# Run this BEFORE destroy-cluster so Karpenter can deprovision GPU nodes and
# the NLB is deleted before the VPC is torn down.
destroy-workloads:
	# Remove ScaledObjects first — otherwise KEDA immediately restores replicas
	-kubectl delete scaledobject vllm-llama3 mistral-7b -n default 2>/dev/null || true
	# Now scale down is safe — nothing will recreate the pods
	-kubectl scale deployment vllm-llama3 mistral-7b --replicas=0 -n default 2>/dev/null || true
	-kubectl delete nodeclaim --all 2>/dev/null || true
	# Uninstall Traefik first — this deletes the NLB
	-helm uninstall traefik -n traefik 2>/dev/null || true
	# Remove all remaining Terraform-managed Kubernetes and Helm resources
	terraform state list | grep -E '^(helm_release|kubectl_manifest|kubernetes_)' | \
		xargs -I{} terraform state rm {}
	@echo "Workloads removed. Wait for GPU nodes to terminate, then run: make destroy-cluster"

# Phase-2 destroy: tear down all AWS infrastructure after workloads are gone.
destroy-cluster:
	terraform destroy -auto-approve

# Full destroy in one step — use only if the cluster already has no workloads
# or if you want Terraform to handle both phases (may fail if NLB blocks VPC deletion).
destroy:
	terraform destroy

fmt:
	terraform fmt -recursive

validate:
	terraform validate

.PHONY: plan plan-cluster plan-workloads apply apply-cluster apply-workloads destroy-workloads destroy-cluster destroy fmt validate
