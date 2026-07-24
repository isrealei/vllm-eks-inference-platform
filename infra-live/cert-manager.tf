# -----------------------------------------------------------------------------
# cert-manager — issues TLS certs via ACME DNS-01 against Route53, using its
# own EKS Pod Identity role scoped to the target hosted zone only.
# -----------------------------------------------------------------------------

data "aws_route53_zone" "this" {
  name         = var.dns_zone_name
  private_zone = false
}

data "aws_iam_policy_document" "cert_manager_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "cert_manager" {
  statement {
    sid       = "GetChange"
    actions   = ["route53:GetChange"]
    resources = ["arn:aws:route53:::change/*"]
  }

  statement {
    sid = "ChangeResourceRecordSets"
    actions = [
      "route53:ChangeResourceRecordSets",
      "route53:ListResourceRecordSets",
    ]
    resources = ["arn:aws:route53:::hostedzone/${data.aws_route53_zone.this.zone_id}"]
  }

  statement {
    sid       = "ListHostedZonesByName"
    actions   = ["route53:ListHostedZonesByName"]
    resources = ["*"]
  }
}

resource "aws_iam_role" "cert_manager" {
  name               = "${var.cluster_name}-cert-manager"
  assume_role_policy = data.aws_iam_policy_document.cert_manager_assume.json
}

resource "aws_iam_role_policy" "cert_manager" {
  name   = "route53-dns01"
  role   = aws_iam_role.cert_manager.id
  policy = data.aws_iam_policy_document.cert_manager.json
}

resource "aws_eks_pod_identity_association" "cert_manager" {
  cluster_name    = var.cluster_name
  namespace       = "cert-manager"
  service_account = "cert-manager"
  role_arn        = aws_iam_role.cert_manager.arn
}

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "1.18.2"

  set = [
    {
      name  = "crds.enabled"
      value = "true"
    }
  ]

  depends_on = [aws_eks_pod_identity_association.cert_manager]
}

resource "kubectl_manifest" "letsencrypt_staging" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt-staging"
    }
    spec = {
      acme = {
        server = "https://acme-staging-v02.api.letsencrypt.org/directory"
        email  = var.acme_email
        privateKeySecretRef = {
          name = "letsencrypt-staging-account-key"
        }
        solvers = [
          {
            dns01 = {
              route53 = {
                region = var.region
              }
            }
          }
        ]
      }
    }
  })

  depends_on = [helm_release.cert_manager]
}

resource "kubectl_manifest" "letsencrypt_prod" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt-prod"
    }
    spec = {
      acme = {
        server = "https://acme-v02.api.letsencrypt.org/directory"
        email  = var.acme_email
        privateKeySecretRef = {
          name = "letsencrypt-prod-account-key"
        }
        solvers = [
          {
            dns01 = {
              route53 = {
                region = var.region
              }
            }
          }
        ]
      }
    }
  })

  depends_on = [helm_release.cert_manager]
}


