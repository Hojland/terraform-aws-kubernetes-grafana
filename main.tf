terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "~> 3.0"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
      version = "~> 1.13"
    }
    helm = {
      source = "hashicorp/helm"
      version = "~> 2.0"
    }
  }
}

locals {
  chart_name    = "grafana"
  chart_version = var.chart_version
  release_name  = "grafana"
  namespace     = var.namespace
  repository    = "https://grafana.github.io/helm-charts"
  bucket_prefix = "grafana"
  bucket_name   = module.s3_bucket.this_s3_bucket_id
  role_name     = local.bucket_name
  provider_url  = replace(var.oidc_provider_issuer_url, "https://", "")

  grafana_ini = {
    server = {
      domain         = var.root_domain
      root_url       = "https://${var.root_domain}"
      enforce_domain = true
    }

    database = {
      type     = "postgres"
      host     = "${module.db.this_db_instance_address}:${module.db.this_db_instance_port}"
      name     = "grafana"
      user     = module.db.this_db_instance_username
      ssl_mode = "require"
    }

    auth = {
      disable_login_form = var.auth_disable_login_form
      oauth_auto_login   = var.oauth_auto_login
    }

    "auth.basic" = {
      enabled = var.auth_enable_basic
    }

    "external_image_storage.s3" = {
      bucket = local.bucket_name
      region = module.s3_bucket.this_s3_bucket_region
    }
  }


  values = {
    ingress = {
      enabled = var.ingress_enabled
      hosts   = var.ingress_hostnames

      annotations = {
        "kubernetes.io/ingress.class" : var.ingress_class
        "cert-manager.io/cluster-issuer" : var.ingress_cluster_issuer
      }

      tls = [
        {
          hosts      = var.ingress_hostnames
          secretName = "grafana-ingress-cert"
        }
      ]
    }

    envFromSecret = kubernetes_secret.grafana.metadata[0].name

    serviceAccount = {
      annotations = {
        "eks.amazonaws.com/role-arn" = module.iam.this_iam_role_arn
      }
    }

    plugins = []

    datasources = {
      "datasources.yaml" = {
        apiVersion = 1
        datasources: var.datasources
      }
    }

    "grafana.ini" = merge(local.grafana_ini, var.oauth_config)
  }
}

data aws_region "grafana" {}
data aws_caller_identity "grafana" {}

module "iam" {
  source = "github.com/terraform-aws-modules/terraform-aws-iam//modules/iam-assumable-role-with-oidc?ref=v3.6.0"

  create_role                   = true
  role_name                     = "${local.release_name}-irsa-${random_id.grafana_rds.dec}"
  provider_url                  = local.provider_url
  oidc_fully_qualified_subjects = ["system:serviceaccount:${local.namespace}:${local.release_name}"]
  tags                          = var.tags
}

data "aws_iam_policy_document" "grafana" {
  statement {
    actions = [
      "s3:ListBucket",
      "s3:PutObject",
      "s3:GetObject"
    ]

    resources = [module.s3_bucket.this_s3_bucket_arn, "${module.s3_bucket.this_s3_bucket_arn}/*"]
  }
}

resource "aws_iam_role_policy" "grafana" {
  name = local.bucket_name
  role = module.iam.this_iam_role_name

  policy = data.aws_iam_policy_document.grafana.json
}

resource "aws_iam_role_policy_attachment" "additional" {
  count = length(var.additional_irsa_role_policy_arns)

  role       = module.iam.this_iam_role_name
  policy_arn = var.additional_irsa_role_policy_arns[count.index]
}

module "s3_bucket" {
  source = "github.com/terraform-aws-modules/terraform-aws-s3-bucket?ref=v1.17.0"

  bucket_prefix = local.bucket_prefix
  acl           = "private"
  force_destroy = true

  versioning = {
    enabled = false
  }

  tags = var.tags
}

resource "random_id" "grafana_rds" {
  keepers = {
    release_name = local.release_name
  }

  byte_length = 10
}

resource "aws_security_group" "grafana_rds" {
  name_prefix = "grafana-rds"
  vpc_id      = var.vpc_id
}

resource "random_password" "grafana_db_password" {
  length  = 16
  special = false
}

module "db" {
  source = "github.com/terraform-aws-modules/terraform-aws-rds?ref=v2.20.0"

  identifier                      = "grafana${random_id.grafana_rds.dec}"
  engine                          = "postgres"
  engine_version                  = "12.3"
  instance_class                  = var.database_instance_type
  allocated_storage               = var.database_storage_size
  storage_encrypted               = false
  name                            = "grafana${random_id.grafana_rds.dec}"
  username                        = "grafana"
  password                        = random_password.grafana_db_password.result
  port                            = "5432"
  vpc_security_group_ids          = [aws_security_group.grafana_rds.id]
  maintenance_window              = "Mon:00:00-Mon:03:00"
  backup_window                   = "03:00-06:00"
  backup_retention_period         = 0
  tags                            = var.tags
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
  subnet_ids                      = var.database_subnets
  family                          = "postgres12"
  major_engine_version            = "12"
  skip_final_snapshot             = var.database_skip_final_snapshot
  final_snapshot_identifier       = var.database_final_snapshot_identifier
  snapshot_identifier             = var.database_snapshot_identifier
  deletion_protection             = false
  auto_minor_version_upgrade      = var.database_auto_minor_version_upgrade
}

resource "aws_security_group_rule" "grafana-cluster-rules" {
  from_port                = 0
  protocol                 = "tcp"
  security_group_id        = aws_security_group.grafana_rds.id
  to_port                  = module.db.this_db_instance_port
  type                     = "ingress"
  source_security_group_id = var.source_security_group
}

resource "kubernetes_namespace" "grafana" {
  count = local.namespace == "kube-system" ? 0 : 1

  metadata {
    name = local.namespace
    annotations = {
      "ingress-whitelist" = "${var.root_domain}"
    }
    labels = {
      "role/grafana" : "true"
      "role/system" : "true"
    }
  }
}

resource "kubernetes_secret" "grafana" {
  metadata {
    name      = "${local.release_name}-credentials"
    namespace = local.namespace
  }

  data = merge({
    GF_DATABASE_PASSWORD = module.db.this_db_instance_password
  }, var.config_secrets)

  depends_on = [kubernetes_namespace.grafana]
}

data "kubernetes_secret" "grafana_secret" {
  depends_on = [ helm_release.grafana-deploy ]
  metadata {
    namespace = kubernetes_namespace.grafana[0].metadata[0].name
    name = "grafana"
  }
}

resource "kubernetes_job" "grafana_createdb" {
  metadata {
    name      = "grafana-createdb"
    namespace = local.namespace
  }

  spec {
    template {
      metadata {
        annotations = {
          "sidecar.istio.io/inject" = "false"
        }
      }

      spec {
        container {
          name  = "grafana-createdb"
          image = "postgres:alpine"

          env {
            name  = "PGHOST"
            value = module.db.this_db_instance_address
          }

          env {
            name  = "PGPORT"
            value = module.db.this_db_instance_port
          }

          env {
            name  = "PGDATABASE"
            value = "postgres"
          }

          env {
            name  = "PGUSER"
            value = module.db.this_db_instance_username
          }

          env {
            name = "PGPASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.grafana.metadata[0].name
                key  = "GF_DATABASE_PASSWORD"
              }
            }
          }

          command = ["/bin/sh", "-c", "psql -tc \"SELECT 1 FROM pg_database WHERE datname = 'grafana'\" | grep -q 1 || psql -c 'CREATE DATABASE grafana'"]
        }
      }
    }
  }

  depends_on = [kubernetes_namespace.grafana]
}

resource "helm_release" "grafana-deploy" {
  name             = local.release_name
  chart            = local.chart_name
  version          = local.chart_version
  repository       = local.repository
  namespace        = local.namespace
  create_namespace = true

  wait   = var.wait 
  values = [yamlencode(local.values), yamlencode(var.chart_values)]

  depends_on = [kubernetes_namespace.grafana]
}
