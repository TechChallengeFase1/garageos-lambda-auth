variable "aws_region" {
  description = "Regiao. A mesma do resto do projeto."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Prefixo dos recursos"
  type        = string
  default     = "garageos"
}

variable "namespace" {
  description = "Namespace onde a aplicacao roda no EKS. Usado para achar o Load Balancer pela tag."
  type        = string
  default     = "garageos"
}

variable "service_name" {
  description = "Nome do Service da API no Kubernetes"
  type        = string
  default     = "garageos-api"
}

variable "jwt_expires_in_seconds" {
  description = "Validade do token emitido. 3600 = 1 hora."
  type        = number
  default     = 3600
}

variable "lambda_runtime" {
  description = <<-EOT
    Runtime da Lambda. Node.js foi escolhido em vez de .NET pelo cold start:
    ~200ms contra 1 a 2 segundos sem Native AOT. Numa autenticacao isso e a
    diferenca entre o login parecer instantaneo ou travado.

    O HS256 e identico nas duas linguagens, entao a API .NET valida o token sem
    saber quem o assinou.
  EOT
  type        = string
  default     = "nodejs22.x"
}
