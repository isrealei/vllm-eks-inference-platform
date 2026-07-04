output "cluster_endpoint" {
  value = aws_eks_cluster.cluster.endpoint
}

output "cluster_name" {
  value = aws_eks_cluster.cluster.name
}

output "cluster_ca_certificate" {
  value = aws_eks_cluster.cluster.certificate_authority[0].data
}
