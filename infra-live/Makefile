
# Fast plan — skips state refresh, uses cached state.
# Use for development iteration when no out-of-band changes have been made.
plan:
	terraform plan -refresh=false -out=tfplan

# Full plan — refreshes all resource state from AWS and Kubernetes APIs before planning.
# Use before any production apply.
plan-full:
	terraform plan -out=tfplan

# Apply the last saved plan file.
apply:
	terraform apply tfplan

# Full refresh + apply in one step. Equivalent to the default terraform apply behaviour.
apply-full:
	terraform apply -auto-approve

# Phase-1 apply: bring up the cluster foundation before Kubernetes providers can connect.
# Required on a fresh deploy where the cluster does not exist yet.
apply-cluster:
	terraform apply -auto-approve \
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

# Phase-2 apply: deploy all workloads after the cluster is running.
apply-workloads:
	terraform apply -auto-approve

destroy:
	terraform destroy

fmt:
	terraform fmt -recursive

validate:
	terraform validate

.PHONY: plan plan-full apply apply-full apply-cluster apply-workloads destroy fmt validate
