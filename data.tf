# ─── O que os outros repositorios publicaram ─────────────────────────────────
#
# Este repositorio nao cria rede, banco nem cluster. Descobre os tres pelo SSM
# e pelas tags. Se a infraestrutura nao estiver de pe, o plan falha aqui -
# antes de criar qualquer coisa.

data "aws_ssm_parameter" "vpc_id" {
  name = "/${var.project}/vpc/id"
}

data "aws_ssm_parameter" "private_subnet_ids" {
  name = "/${var.project}/vpc/private-subnet-ids"
}

# O "cracha" criado pelo garageos-infra-database. Anexa-lo a Lambda e o que
# libera a porta 5432 do RDS para ela - o mesmo mecanismo usado nos nos do EKS.
data "aws_ssm_parameter" "rds_client_sg_id" {
  name = "/${var.project}/${local.env}/rds/client-security-group-id"
}

data "aws_ssm_parameter" "rds_endpoint" {
  name = "/${var.project}/${local.env}/rds/endpoint"
}

data "aws_ssm_parameter" "rds_port" {
  name = "/${var.project}/${local.env}/rds/port"
}

data "aws_ssm_parameter" "rds_dbname" {
  name = "/${var.project}/${local.env}/rds/dbname"
}

data "aws_ssm_parameter" "rds_secret_arn" {
  name = "/${var.project}/${local.env}/rds/secret-arn"
}

data "aws_ssm_parameter" "app_secret_arn" {
  name = "/${var.project}/app/secret-arn"
}

# ─── Conteudo dos segredos ───────────────────────────────────────────────────
#
# Lidos aqui, no apply, e injetados como variavel de ambiente da Lambda.
#
# POR QUE NAO LER EM RUNTIME: a Lambda fica em subnet privada e o bootstrap nao
# criou NAT Gateway (economia de ~US$ 32/mes). Sem rota para a internet, ela
# nao alcanca a API do Secrets Manager. As alternativas seriam um VPC endpoint
# de interface (~US$ 14/mes) ou o NAT.
#
# E o mesmo padrao ja usado na aplicacao, onde a pipeline le o Secrets Manager
# e cria o Secret do Kubernetes: a fonte da verdade continua sendo o cofre.

data "aws_secretsmanager_secret_version" "rds" {
  secret_id = data.aws_ssm_parameter.rds_secret_arn.value
}

data "aws_secretsmanager_secret_version" "app" {
  secret_id = data.aws_ssm_parameter.app_secret_arn.value
}

# ─── Load Balancer da aplicacao ──────────────────────────────────────────────
#
# Criado pelo Kubernetes, nao pelo Terraform - por isso e descoberto por tag em
# vez de referenciado. E o destino para onde o API Gateway encaminha as
# requisicoes ja autenticadas.
data "aws_lb" "api" {
  tags = {
    "kubernetes.io/service-name" = "${var.namespace}/${var.service_name}"
  }
}

locals {
  private_subnet_ids = split(",", nonsensitive(data.aws_ssm_parameter.private_subnet_ids.value))
  rds_client_sg_id   = nonsensitive(data.aws_ssm_parameter.rds_client_sg_id.value)
  rds_endpoint       = nonsensitive(data.aws_ssm_parameter.rds_endpoint.value)
  rds_port           = nonsensitive(data.aws_ssm_parameter.rds_port.value)
  rds_dbname         = nonsensitive(data.aws_ssm_parameter.rds_dbname.value)

  rds          = jsondecode(data.aws_secretsmanager_secret_version.rds.secret_string)
  segredos_app = jsondecode(data.aws_secretsmanager_secret_version.app.secret_string)
}
