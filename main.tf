
locals {
  chart_name    = "grafana"
  chart_version = var.chart_version
  release_name  = "grafana"
  namespace     = var.namespace
  repository    = "https://kubernetes-charts.storage.googleapis.com"
  bucket_name   = "grafana-${data.aws_caller_identity.grafana.account_id}"
  provider_url  = replace(var.oidc_provider_issuer_url, "https://", "")

  values = {
    envFromSecret = kubernetes_secret.grafana.metadata[0].name
    serviceAccount = {
      annotations = {
        "eks.amazonaws.com/role-arn" = module.iam.this_iam_role_arn
      }
    }
    plugins = []
    "grafana.ini" = {
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
      "auth.github" = {
        enabled               = true
        allow_sign_up         = true
        client_id             = var.oauth_github_client_id
        client_secret         = var.oauth_github_client_secret
        scopes                = "user:email,read:org"
        auth_url              = "https://github.com/login/oauth/authorize"
        token_url             = "https://github.com/login/oauth/access_token"
        api_url               = "https://api.github.com/user"
        team_ids              = join(",", var.oauth_github_team_ids)
        allowed_organizations = join(",", var.oauth_github_organizations)
      }
      "external_image_storage.s3" = {
        bucket = local.bucket_name
        region = data.aws_region.grafana.name
      }
    }
  }

}

data aws_region "grafana" {}
data aws_caller_identity "grafana" {}

module "iam" {
  source = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"

  create_role                   = true
  role_name                     = "${local.release_name}-irsa-${random_id.grafana_rds.dec}"
  provider_url                  = local.provider_url
  oidc_fully_qualified_subjects = ["system:serviceaccount:${local.namespace}:${local.release_name}"]

  tags = var.tags
}

data "aws_iam_policy_document" "grafana" {
  statement {
    actions = [
      "s3:ListBucket",
      "s3:PutObject",
      "s3:GetObject"
    ]
    resources = [module.grafana_s3_bucket.this_s3_bucket_arn, "${module.grafana_s3_bucket.this_s3_bucket_arn}/*"]
  }
}

resource "aws_iam_role_policy" "grafana" {
  name = local.bucket_name
  role = module.iam.this_iam_role_name

  policy = data.aws_iam_policy_document.grafana.json
}


module "grafana_s3_bucket" {
  source = "terraform-aws-modules/s3-bucket/aws"

  bucket_prefix = local.bucket_name
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
  name_prefix = "grafana_rds"
  vpc_id      = var.vpc_id
}

resource "random_password" "grafana_db_password" {
  length  = 16
  special = true
}

module "db" {
  source = "terraform-aws-modules/rds/aws"

  identifier                      = "grafana${random_id.grafana_rds.dec}"
  engine                          = "postgres"
  engine_version                  = "12.2"
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
  final_snapshot_identifier       = local.release_name
  deletion_protection             = false
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
  metadata {
    name = local.namespace
  }
}
resource "kubernetes_secret" "grafana" {
  metadata {
    name      = "${local.release_name}-credentials"
    namespace = kubernetes_namespace.grafana.metadata[0].name
  }
  data = {
    GF_DATABASE_PASSWORD = module.db.this_db_instance_password
  }
}

resource "kubernetes_job" "grafana_createdb" {
  metadata {
    name      = "grafana-createdb"
    namespace = kubernetes_namespace.grafana.metadata[0].name
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
}

resource "helm_release" "grafana-deploy" {
  name             = local.release_name
  chart            = local.chart_name
  version          = local.chart_version
  repository       = local.repository
  namespace        = kubernetes_job.grafana_createdb.metadata[0].namespace
  create_namespace = true

  wait   = true
  values = [yamlencode(local.values)]

}
