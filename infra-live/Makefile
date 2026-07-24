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

destroy:
	terraform destroy

fmt:
	terraform fmt -recursive

validate:
	terraform validate

.PHONY: plan plan-cluster plan-workloads apply apply-cluster apply-workloads destroy fmt validate
