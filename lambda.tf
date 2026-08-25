# ─── Empacotamento ───────────────────────────────────────────────────────────
#
# O diretorio lambda/ existe justamente para isto: contem apenas o codigo e as
# dependencias, entao o zip sai limpo sem lista de exclusoes. Se o codigo
# estivesse na raiz, o zip arrastaria .terraform junto - centenas de MB, acima
# do limite de 250 MB da Lambda.

data "archive_file" "codigo" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/build/lambda.zip"
}

# ─── Permissoes ──────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${local.name}-lambda-auth"
  description        = "Vestida pelas funcoes de autenticacao por CPF"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

# Logs no CloudWatch.
resource "aws_iam_role_policy_attachment" "basica" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Permite criar e apagar as ENIs que ligam a Lambda a VPC. Sem isto a funcao
# fica presa em "Pending" e as invocacoes expiram sem mensagem util.
resource "aws_iam_role_policy_attachment" "vpc" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Nao ha policy de Secrets Manager de proposito: os segredos chegam por
# variavel de ambiente, injetados no apply. A funcao nao fala com o cofre em
# tempo de execucao, entao nao precisa de permissao para isso.

# ─── Funcao 1: emite o token ─────────────────────────────────────────────────

resource "aws_lambda_function" "auth" {
  function_name = "${local.name}-auth"
  description   = "Valida o CPF, consulta o cliente no RDS e devolve um JWT"

  role    = aws_iam_role.lambda.arn
  runtime = var.lambda_runtime
  handler = "index.handler"

  filename         = data.archive_file.codigo.output_path
  source_code_hash = data.archive_file.codigo.output_base64sha256

  # Consulta ao banco: 10s cobre com folga, inclusive a conexao fria.
  timeout     = 10
  memory_size = 256

  # Dentro da VPC, nas subnets privadas, com o cracha de acesso ao RDS.
  # E o mesmo Security Group anexado aos nos do EKS - por isso a Lambda alcanca
  # o banco sem nenhuma regra nova.
  vpc_config {
    subnet_ids         = local.private_subnet_ids
    security_group_ids = [local.rds_client_sg_id]
  }

  environment {
    variables = {
      # Lidas automaticamente pela biblioteca `pg`, sem montar URI nem escapar
      # caracteres especiais da senha.
      PGHOST     = local.rds_endpoint
      PGPORT     = local.rds_port
      PGDATABASE = local.rds_dbname
      PGUSER     = local.rds.username
      PGPASSWORD = local.rds.password

      # A MESMA chave que a API .NET usa para validar. Vem do mesmo segredo no
      # Secrets Manager - e o que impede a divergencia que faria a API rejeitar
      # silenciosamente todo token emitido aqui.
      JWT_SECRET_KEY = local.segredos_app.jwtSecretKey
      JWT_ISSUER     = local.segredos_app.jwtIssuer
      JWT_AUDIENCE   = local.segredos_app.jwtAudience

      JWT_EXPIRES_IN_SECONDS = tostring(var.jwt_expires_in_seconds)
    }
  }

  depends_on = [aws_iam_role_policy_attachment.vpc]
}

# ─── Funcao 2: valida o token no gateway ─────────────────────────────────────
#
# FORA da VPC de proposito: ela so confere uma assinatura HMAC, nao toca no
# banco. Sem ENI para criar, o cold start e muito menor - e ela roda em TODA
# requisicao protegida.

resource "aws_lambda_function" "authorizer" {
  function_name = "${local.name}-authorizer"
  description   = "Valida o JWT antes de a requisicao chegar ao cluster"

  role    = aws_iam_role.lambda.arn
  runtime = var.lambda_runtime
  handler = "index.authorizer"

  filename         = data.archive_file.codigo.output_path
  source_code_hash = data.archive_file.codigo.output_base64sha256

  timeout     = 5
  memory_size = 128

  environment {
    variables = {
      JWT_SECRET_KEY = local.segredos_app.jwtSecretKey
      JWT_ISSUER     = local.segredos_app.jwtIssuer
      JWT_AUDIENCE   = local.segredos_app.jwtAudience
    }
  }
}

# ─── Retencao dos logs ───────────────────────────────────────────────────────
# Sem isto o CloudWatch guarda para sempre e vira custo silencioso.

resource "aws_cloudwatch_log_group" "auth" {
  name              = "/aws/lambda/${aws_lambda_function.auth.function_name}"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "authorizer" {
  name              = "/aws/lambda/${aws_lambda_function.authorizer.function_name}"
  retention_in_days = 7
}
