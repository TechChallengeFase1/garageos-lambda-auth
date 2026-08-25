# ─── API Gateway HTTP API ────────────────────────────────────────────────────
#
# A porta de entrada da solucao. Duas rotas:
#
#   POST /auth        -> Lambda de autenticacao.   PUBLICA (e onde se obtem o
#                        token; exigir token aqui seria circular)
#   ANY  /{proxy+}    -> Load Balancer da API.     PROTEGIDA pelo authorizer
#
# HTTP API (v2) em vez de REST API (v1): mesma funcionalidade para este caso,
# ~70% mais barato e configuracao bem menor.

resource "aws_apigatewayv2_api" "main" {
  name          = "${local.name}-api"
  description   = "Porta de entrada do GarageOS: autenticacao por CPF e acesso as APIs protegidas"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"]
    allow_headers = ["content-type", "authorization", "x-correlation-id"]
  }
}

# ─── Authorizer ──────────────────────────────────────────────────────────────
#
# Tipo REQUEST, e nao JWT.
#
# O HTTP API tem um authorizer JWT nativo, mas ele exige um provedor OIDC/OAuth2
# que exponha JWKS - Cognito, Auth0 e afins. Nosso token e HS256, assinado com
# uma chave simetrica: nao existe chave publica para o gateway buscar. Por isso
# a validacao roda numa Lambda propria.

resource "aws_apigatewayv2_authorizer" "jwt" {
  api_id          = aws_apigatewayv2_api.main.id
  name            = "${local.name}-jwt"
  authorizer_type = "REQUEST"

  authorizer_uri                    = aws_lambda_function.authorizer.invoke_arn
  authorizer_payload_format_version = "2.0"

  # Resposta no formato { isAuthorized: bool, context: {...} }, em vez de um
  # documento de policy IAM completo.
  enable_simple_responses = true

  # A resposta e cacheada por 5 minutos POR VALOR do header Authorization.
  # Evita invocar a Lambda em toda requisicao do mesmo cliente.
  identity_sources                 = ["$request.header.Authorization"]
  authorizer_result_ttl_in_seconds = 300
}

resource "aws_lambda_permission" "authorizer" {
  statement_id  = "AllowApiGatewayInvokeAuthorizer"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.authorizer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*"
}

# ─── Rota publica: obter o token ─────────────────────────────────────────────

resource "aws_apigatewayv2_integration" "auth" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.auth.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "auth" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "POST /auth"
  target    = "integrations/${aws_apigatewayv2_integration.auth.id}"
  # Sem authorizer: e aqui que o token e obtido.
}

resource "aws_lambda_permission" "auth" {
  statement_id  = "AllowApiGatewayInvokeAuth"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.auth.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*"
}

# ─── Rota protegida: a aplicacao no EKS ──────────────────────────────────────
#
# Integracao HTTP_PROXY apontando para o Load Balancer, descoberto por tag em
# data.tf.
#
# TRADE-OFF ACEITO: o NLB e internet-facing, entao continua acessivel
# diretamente, sem passar pelo gateway. A alternativa correta seria um NLB
# interno com VPC Link. Registrado como ADR.

resource "aws_apigatewayv2_integration" "api" {
  api_id             = aws_apigatewayv2_api.main.id
  integration_type   = "HTTP_PROXY"
  integration_uri    = "http://${data.aws_lb.api.dns_name}/{proxy}"
  integration_method = "ANY"

  # Repassa a identidade extraida do token para a aplicacao, para ela nao
  # precisar decodificar o JWT de novo.
  request_parameters = {
    "overwrite:header.X-Cliente-Id"  = "$context.authorizer.clienteId"
    "overwrite:header.X-Cliente-Cpf" = "$context.authorizer.cpf"
  }
}

resource "aws_apigatewayv2_route" "api" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "ANY /{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.api.id}"

  # Sem token valido, a requisicao e recusada AQUI - nao chega ao cluster.
  authorization_type = "CUSTOM"
  authorizer_id      = aws_apigatewayv2_authorizer.jwt.id
}

# ─── Stage ───────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "gateway" {
  name              = "/aws/apigateway/${local.name}"
  retention_in_days = 7
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.gateway.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      responseLength = "$context.responseLength"
      latencia       = "$context.responseLatency"
      # Por que a requisicao foi recusada, quando foi.
      authorizerErro = "$context.authorizer.error"
      integracaoErro = "$context.integration.error"
    })
  }

  # Protege contra um cliente sozinho consumir a capacidade - o "controle de
  # chamadas" que o enunciado cita entre as funcoes do API Gateway.
  default_route_settings {
    throttling_burst_limit = 100
    throttling_rate_limit  = 50
  }
}
